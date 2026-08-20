# Fastboot Boot-till-ping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce power-on → first ICMP ping reply on `192.168.132.100` (eth0) for the Hadron NGX012, via universal bootloader/kernel/DTB wins in the base image plus a dedicated `hadron-image-fastboot` image, every change verified on real hardware.

**Architecture:** Measurement-driven, phased. A host harness power-cycles the board (zup PSU) and times power-on→ICMP; each optimization is applied, rebuilt, flashed, re-measured, then kept or reverted based on the measured median. Universal wins land in the machine conf / base image; aggressive payload stripping lands in a new fastboot image recipe.

**Tech Stack:** Yocto (scarthgap), kas, meta-tegra, meta-hadron, systemd, TDK-Lambda ZUP PSU (zup-power-supply skill), CTI L4T initrd flash.

## Global Constraints

- Machine: `hadron-ngx012` (Jetson Orin Nano 4GB, p3767-0003). Rootfs always on `nvme0n1p1`.
- Metric = **median power-on → first ICMP reply** on `192.168.132.100`, host-side, N≥5 runs.
- `hadron-image-base` AND `hadron-image-desktop` MUST remain bootable and functional. Only universal (risk-free) wins touch them; aggressive stripping is fastboot-image-only.
- Required payload in fastboot image (must be present, may start AFTER ping): `docker-moby`, `nvidia-container-toolkit`, `ffmpeg`, `pymavlink`, `wasp-version`, `hadron-network`, sshd, `hadron-serial-symlinks`, `bmi160-config`. NOT required: CUDA stack, opencv, full gstreamer plugin set.
- Init system stays **systemd** (busybox rejected — see spec §5a).
- Kernel defconfig changes ARE permitted where measured to help.
- Build: `kas build kas.yml` (default target base); fastboot built by overriding target.
- One git commit per experiment on branch `fastboot_opt` for easy revert.
- Static eth0 config lives in `sources/meta-hadron/recipes-connectivity/hadron-network/files/10-eth0.network` (systemd-networkd). Current kernel args: `net.ifnames=0` + `console=ttyTHS1,115200 console=tty0` in `sources/meta-hadron/conf/machine/hadron-ngx012.conf`.
- Flash procedure: per repo `.github/copilot-instructions.md` (CTI `l4t_initrd_flash.sh --network usb0`, inject Yocto `tegraflash.tar.gz`). Board must be in USB recovery mode.
- Design spec: `docs/superpowers/specs/2026-08-20-fastboot-boot-till-ping-design.md`.

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/boot-timing/measure-ping.sh` | Power-cycle via zup + host ping-loop; print & record median power-on→ICMP ms |
| `scripts/boot-timing/collect-ondevice.sh` | SSH to running board, dump `systemd-analyze` + dmesg for per-stage breakdown |
| `scripts/boot-timing/record.py` | Insert a measured run into `boot_runs` SQLite table; print comparison vs baseline |
| `scripts/boot-timing/README.md` | How to run the harness, env vars, interpreting output |
| `sources/meta-hadron/conf/machine/hadron-ngx012.conf` | extlinux timeout, quiet cmdline, no-initramfs, bootloader log silence |
| `sources/meta-hadron/recipes-bsp/cti-board-support/files/*.dts*` | DTB node disables (Phase 1) |
| `sources/meta-hadron/recipes-core/images/hadron-image-fastboot.bb` | New fastboot image recipe |
| `sources/meta-hadron/recipes-kernel/linux/linux-jammy-nvidia-tegra_%.bbappend` + `.cfg` | defconfig fragment: built-in NIC/NVMe, driver strip (Phase 3) |

---

## Task 1: Boot-timing measurement harness

**Files:**
- Create: `scripts/boot-timing/measure-ping.sh`
- Create: `scripts/boot-timing/record.py`
- Create: `scripts/boot-timing/collect-ondevice.sh`
- Create: `scripts/boot-timing/README.md`

**Interfaces:**
- Consumes: zup-power-supply skill at `/home/ranshal/.copilot/skills/zup-power-supply/scripts/zup_control.py` (`reboot [delay]`, `on`, `off`, `status`). Target IP `192.168.132.100`.
- Produces: SQLite table `boot_runs(id, ts, experiment_label, phase, median_ms, min_ms, n_runs, git_sha, notes)` in the session DB; `measure-ping.sh` prints `MEDIAN_MS=<n>` as its last line.

- [ ] **Step 1: Create the SQLite results table**

Run via the sql tool (session DB):
```sql
CREATE TABLE IF NOT EXISTS boot_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT DEFAULT (datetime('now')),
  experiment_label TEXT NOT NULL,
  phase TEXT,
  median_ms INTEGER,
  min_ms INTEGER,
  n_runs INTEGER,
  git_sha TEXT,
  notes TEXT
);
```

- [ ] **Step 2: Write `measure-ping.sh`**

```bash
#!/usr/bin/env bash
# Power-cycle the board and time power-on -> first ICMP reply.
# Usage: measure-ping.sh [N_RUNS] [TARGET_IP]
# Prints per-run ms and a final "MEDIAN_MS=<n>" line.
set -euo pipefail

N="${1:-5}"
TARGET="${2:-192.168.132.100}"
ZUP="/home/ranshal/.copilot/skills/zup-power-supply/scripts/zup_control.py"
OFF_SETTLE="${OFF_SETTLE:-5}"     # seconds powered off before power-on
MAX_WAIT="${MAX_WAIT:-120}"       # abort a run after this many seconds

times=()
for i in $(seq 1 "$N"); do
  python "$ZUP" off >/dev/null
  sleep "$OFF_SETTLE"
  start=$(date +%s.%N)
  python "$ZUP" on >/dev/null
  # Tight loop: one ping every 200ms until first reply or timeout.
  while :; do
    now=$(date +%s.%N)
    elapsed=$(echo "$now - $start" | bc -l)
    if (( $(echo "$elapsed > $MAX_WAIT" | bc -l) )); then
      echo "run $i: TIMEOUT after ${MAX_WAIT}s" >&2
      times+=("999999")
      break
    fi
    if ping -c1 -W1 "$TARGET" >/dev/null 2>&1; then
      ms=$(echo "($now - $start) * 1000 / 1" | bc)
      echo "run $i: ${ms} ms"
      times+=("$ms")
      break
    fi
    sleep 0.2
  done
done

# Median
sorted=($(printf '%s\n' "${times[@]}" | sort -n))
mid=$(( ${#sorted[@]} / 2 ))
if (( ${#sorted[@]} % 2 == 1 )); then
  median=${sorted[$mid]}
else
  median=$(( (${sorted[$((mid-1))]} + ${sorted[$mid]}) / 2 ))
fi
echo "MIN_MS=${sorted[0]}"
echo "MEDIAN_MS=${median}"
```

- [ ] **Step 3: Write `record.py`**

```python
#!/usr/bin/env python3
"""Record a measured boot run into the session boot_runs table.
Usage: record.py --label OPT-x --phase 1 --median 12345 --min 12000 --n 5 --sha $(git rev-parse --short HEAD) --notes "..."
Reads MEDIAN_MS/MIN_MS from stdin if --median omitted.
"""
import argparse, sqlite3, os, sys, subprocess

def find_db():
    # Session DB path is provided by the runtime; fall back to a local file.
    return os.environ.get("BOOT_RUNS_DB", "scripts/boot-timing/boot_runs.sqlite")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--label", required=True)
    p.add_argument("--phase", default="")
    p.add_argument("--median", type=int)
    p.add_argument("--min", type=int, dest="min_ms")
    p.add_argument("--n", type=int, default=5)
    p.add_argument("--sha", default="")
    p.add_argument("--notes", default="")
    a = p.parse_args()

    median, min_ms = a.median, a.min_ms
    if median is None:
        for line in sys.stdin:
            if line.startswith("MEDIAN_MS="):
                median = int(line.strip().split("=", 1)[1])
            if line.startswith("MIN_MS="):
                min_ms = int(line.strip().split("=", 1)[1])

    db = find_db()
    os.makedirs(os.path.dirname(db), exist_ok=True)
    con = sqlite3.connect(db)
    con.execute("""CREATE TABLE IF NOT EXISTS boot_runs(
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT DEFAULT (datetime('now')),
        experiment_label TEXT NOT NULL, phase TEXT, median_ms INTEGER,
        min_ms INTEGER, n_runs INTEGER, git_sha TEXT, notes TEXT)""")
    con.execute(
        "INSERT INTO boot_runs(experiment_label,phase,median_ms,min_ms,n_runs,git_sha,notes) VALUES (?,?,?,?,?,?,?)",
        (a.label, a.phase, median, min_ms, a.n, a.sha, a.notes))
    con.commit()
    rows = list(con.execute("SELECT experiment_label,phase,median_ms,min_ms FROM boot_runs ORDER BY id"))
    print(f"Recorded {a.label}: median={median}ms min={min_ms}ms")
    print("History:")
    for r in rows:
        print(f"  {r[0]:20s} phase={r[1]:6s} median={r[2]}ms min={r[3]}ms")

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Write `collect-ondevice.sh`**

```bash
#!/usr/bin/env bash
# Dump per-stage boot breakdown from a running board (SSH).
# Usage: collect-ondevice.sh [IP] [USER]
set -euo pipefail
IP="${1:-192.168.132.100}"
USER="${2:-ubuntu}"
SSH="sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ${USER}@${IP}"
echo "=== systemd-analyze time ==="
$SSH "systemd-analyze time" || true
echo "=== systemd-analyze blame (top 20) ==="
$SSH "systemd-analyze blame | head -20" || true
echo "=== systemd-analyze critical-chain ==="
$SSH "systemd-analyze critical-chain" || true
echo "=== dmesg: eth0 / link up timestamps ==="
$SSH "sudo dmesg | grep -iE 'eth0|link up|nvme|Run /sbin/init'" || true
```

- [ ] **Step 5: Write `README.md`**

```markdown
# Boot-timing harness

Measures power-on -> first ICMP reply on the Hadron board, power-cycled via the ZUP PSU.

## Prereqs
- ZUP PSU wired to the board, reachable per `.env` (see zup-power-supply skill).
- `bc` installed on host (`apt install bc`).
- Board flashed with the image under test; static IP 192.168.132.100 on eth0.

## Run
```bash
# 5 runs, record against a label
./measure-ping.sh 5 192.168.132.100 | tee /tmp/run.txt
./record.py --label baseline --phase 0 --n 5 \
  --sha "$(git rev-parse --short HEAD)" --notes "phase0 baseline" < /tmp/run.txt

# Per-stage breakdown once the board is up
./collect-ondevice.sh
```
Keep a change only if MEDIAN_MS drops (or holds) vs the previous recorded run
AND the board still boots + answers ping. Otherwise `git revert` the experiment.
```

- [ ] **Step 6: Make scripts executable and smoke-test the ZUP link**

Run:
```bash
chmod +x scripts/boot-timing/*.sh scripts/boot-timing/record.py
python /home/ranshal/.copilot/skills/zup-power-supply/scripts/zup_control.py status
```
Expected: PSU status prints voltage/current (confirms harness can control power). If it errors, fix `.env`/wiring before proceeding — the whole plan depends on this.

- [ ] **Step 7: Commit**

```bash
git add scripts/boot-timing/
git commit -m "feat(boot-timing): add power-on-to-ping measurement harness"
```

---

## Task 2: Establish Phase-0 baseline

**Files:** none (measurement only).

**Interfaces:**
- Consumes: Task 1 harness; a board flashed with **current** `hadron-image-base` (unmodified `fastboot_opt` == `main` behavior).
- Produces: a `boot_runs` row labelled `baseline` — the number every later task compares against.

- [ ] **Step 1: Build current base image**

Run: `kas build kas.yml`
Expected: build succeeds; `build/tmp/deploy/images/hadron-ngx012/hadron-image-base-hadron-ngx012.rootfs.tegraflash.tar.gz` exists.

- [ ] **Step 2: Flash the board**

Follow `.github/copilot-instructions.md` "Flashing the Device" (board in USB recovery mode, `l4t_initrd_flash.sh --network usb0`, inject Yocto tarball).
Expected: `Flash is successful`, board boots, `ping 192.168.132.100` replies.

- [ ] **Step 3: Measure baseline (N=5)**

Run:
```bash
cd scripts/boot-timing
./measure-ping.sh 5 192.168.132.100 | tee /tmp/baseline.txt
./record.py --label baseline --phase 0 --n 5 --sha "$(git rev-parse --short HEAD)" --notes "unmodified base" < /tmp/baseline.txt
```
Expected: prints `MEDIAN_MS=<n>`; a `baseline` row recorded.

- [ ] **Step 4: Capture per-stage breakdown**

Run: `./collect-ondevice.sh 192.168.132.100 ubuntu | tee /tmp/baseline-stages.txt`
Expected: `systemd-analyze` output + eth0/link-up dmesg lines captured. Note which stage (bootloader vs kernel vs userspace) dominates — this prioritizes later tasks.

- [ ] **Step 5: Commit the baseline record**

```bash
git add scripts/boot-timing/boot_runs.sqlite
git commit -m "chore(boot-timing): record phase-0 baseline median"
```

---

## Task 3: Universal win — extlinux menu timeout = 0

**Files:**
- Modify: `sources/meta-hadron/conf/machine/hadron-ngx012.conf`

**Interfaces:**
- Consumes: `UBOOT_EXTLINUX_TIMEOUT` (meta-tegra `l4t-extlinux-config.bbclass`, units of 1/10s).
- Produces: extlinux `.conf` with `TIMEOUT 0` — no boot-menu wait.

- [ ] **Step 1: Add the timeout override**

Add to `sources/meta-hadron/conf/machine/hadron-ngx012.conf` (after the existing `UBOOT_EXTLINUX_KERNEL_ARGS:append` line):
```
# Fastboot: never wait at the extlinux boot menu (recovery is via reflash).
UBOOT_EXTLINUX_TIMEOUT = "0"
```

- [ ] **Step 2: Rebuild**

Run: `kas build kas.yml`
Expected: build succeeds.

- [ ] **Step 3: Verify the generated extlinux config**

Run: `grep -i timeout build/tmp/deploy/images/hadron-ngx012/extlinux.conf 2>/dev/null || find build/tmp -name extlinux.conf -exec grep -i timeout {} +`
Expected: `TIMEOUT 0` present.

- [ ] **Step 4: Flash + measure**

Flash per the standard procedure, then:
```bash
cd scripts/boot-timing
./measure-ping.sh 5 | tee /tmp/opt-extlinux.txt
./record.py --label OPT-extlinux-timeout --phase 1 --n 5 --sha "$(git rev-parse --short HEAD)" --notes "TIMEOUT=0" < /tmp/opt-extlinux.txt
```
Expected: median ≤ baseline. If it regresses or board fails to boot, `git checkout -- sources/meta-hadron/conf/machine/hadron-ngx012.conf` and skip.

- [ ] **Step 5: Commit (only if kept)**

```bash
git add sources/meta-hadron/conf/machine/hadron-ngx012.conf scripts/boot-timing/boot_runs.sqlite
git commit -m "perf(boot): set extlinux TIMEOUT=0 (skip boot-menu wait)"
```

---

## Task 4: Universal win — quiet kernel cmdline

**Files:**
- Modify: `sources/meta-hadron/conf/machine/hadron-ngx012.conf`

**Interfaces:**
- Consumes: existing `UBOOT_EXTLINUX_KERNEL_ARGS:append` (line 42) carrying console args.
- Produces: kernel cmdline additionally containing `quiet loglevel=0`.

- [ ] **Step 1: Append quiet flags**

Change the existing append in `sources/meta-hadron/conf/machine/hadron-ngx012.conf`:
```
UBOOT_EXTLINUX_KERNEL_ARGS:append = " console=ttyTHS1,115200 console=tty0 quiet loglevel=0"
```
(Console kept so serial + `dmesg` still work post-boot.)

- [ ] **Step 2: Rebuild**

Run: `kas build kas.yml`
Expected: build succeeds.

- [ ] **Step 3: Verify cmdline**

Run: `find build/tmp -name extlinux.conf -exec grep -i append {} +`
Expected: APPEND line contains `quiet loglevel=0`.

- [ ] **Step 4: Flash + measure**

```bash
cd scripts/boot-timing
./measure-ping.sh 5 | tee /tmp/opt-quiet.txt
./record.py --label OPT-quiet --phase 1 --n 5 --sha "$(git rev-parse --short HEAD)" --notes "quiet loglevel=0" < /tmp/opt-quiet.txt
```
Expected: median ≤ previous. Verify `ssh ubuntu@192.168.132.100 sudo dmesg | tail` still works (log ring intact). Revert if regressed.

- [ ] **Step 5: Commit (only if kept)**

```bash
git add sources/meta-hadron/conf/machine/hadron-ngx012.conf scripts/boot-timing/boot_runs.sqlite
git commit -m "perf(boot): quiet kernel console (quiet loglevel=0)"
```

---

## Task 5: Universal win — eliminate boot initramfs

**Files:**
- Modify: `sources/meta-hadron/conf/machine/hadron-ngx012.conf`

**Interfaces:**
- Consumes: meta-tegra `INITRAMFS_IMAGE ?= "tegra-minimal-initramfs"` (tegra-common.inc:75) and `TNSPEC_BOOTDEV = "nvme0n1p1"` (orin-nx.inc:9). Rootfs is always on `nvme0n1p1`.
- Produces: boot.img with no bundled initrd; kernel mounts `root=/dev/nvme0n1p1` directly. **Prerequisite:** NVMe driver built-in (verified in Step 1). If NVMe is a module, this task is BLOCKED until Task 9 builds it in — do Task 9 first, then return.

- [ ] **Step 1: Verify NVMe driver is built-in (not a module)**

Run (on the currently-booted board): `ssh ubuntu@192.168.132.100 "zcat /proc/config.gz | grep -E 'CONFIG_BLK_DEV_NVME|CONFIG_NVME_CORE'"`
Expected: values are `=y` (built-in). If `=m`, mark this task blocked, complete Task 9 first (build them `=y`), then resume here.

- [ ] **Step 2: Disable the initramfs for this machine**

Add to `sources/meta-hadron/conf/machine/hadron-ngx012.conf`:
```
# Fastboot: rootfs is always on nvme0n1p1 and the NVMe driver is built-in,
# so no boot initramfs is needed. Boot the rootfs directly.
INITRAMFS_IMAGE = ""
INITRAMFS_IMAGE_BUNDLE = "0"
```

- [ ] **Step 3: Rebuild**

Run: `kas build kas.yml`
Expected: build succeeds; `boot.img` produced without an initrd. `find build/tmp -name extlinux.conf -exec grep -i initrd {} +` shows no INITRD line (or empty).

- [ ] **Step 4: Flash + measure**

```bash
cd scripts/boot-timing
./measure-ping.sh 5 | tee /tmp/opt-noinitramfs.txt
./record.py --label OPT-no-initramfs --phase 1 --n 5 --sha "$(git rev-parse --short HEAD)" --notes "root=/dev/nvme0n1p1 direct" < /tmp/opt-noinitramfs.txt
```
Expected: board boots straight to rootfs; median < previous. If the board fails to mount root, revert immediately.

- [ ] **Step 5: Commit (only if kept)**

```bash
git add sources/meta-hadron/conf/machine/hadron-ngx012.conf scripts/boot-timing/boot_runs.sqlite
git commit -m "perf(boot): drop boot initramfs, mount nvme rootfs directly"
```

---

## Task 6: Universal win — silence MB1/BPMP bootloader serial logging

**Files:**
- Modify: `sources/meta-hadron/conf/machine/hadron-ngx012.conf`

**Interfaces:**
- Consumes: meta-tegra bootloader log-level variables. Exact names MUST be confirmed against the pinned meta-tegra commit (`447c214…`) before use — candidates: `TEGRA_MB1_LOG_LEVEL`, BPMP UART logging flags in the BCT.
- Produces: bootloader emits less/no serial log → less pre-kernel time.

- [ ] **Step 1: Find the real variable names in the pinned meta-tegra**

Run:
```bash
grep -rniE "MB1_LOG|LOG_LEVEL|BPMP.*(LOG|UART|SERIAL)|enable_.*log" meta-tegra/ | grep -iv test | head -30
```
Expected: identify the actual variable(s) / BCT knob(s) controlling MB1/BPMP serial verbosity. If none is a simple bbvar, this may require a BCT `.dts` override (like the existing `TEGRA_FLASHVAR_MB2BCT_CFG`). Record what you find in a comment.

- [ ] **Step 2: Apply the log-silence setting**

Add the confirmed variable(s) to `sources/meta-hadron/conf/machine/hadron-ngx012.conf`, e.g.:
```
# Fastboot: minimize MB1/BPMP serial logging (serial is only needed post-kernel).
# <VARIABLE NAME CONFIRMED IN STEP 1> = "0"
```
Replace the placeholder with the real variable(s) from Step 1. If it requires a BCT dts override, add the file under `recipes-bsp/cti-board-support/files/` and wire the matching `TEGRA_FLASHVAR_*` var.

- [ ] **Step 3: Rebuild + reflash**

Run: `kas build kas.yml`, then flash. (This touches QSPI/bootloader, so a full flash — not kernel-only — is required.)
Expected: build + flash succeed; board still reaches UEFI and boots.

- [ ] **Step 4: Measure**

```bash
cd scripts/boot-timing
./measure-ping.sh 5 | tee /tmp/opt-mb1log.txt
./record.py --label OPT-mb1-bpmp-log --phase 1 --n 5 --sha "$(git rev-parse --short HEAD)" --notes "bootloader serial log off" < /tmp/opt-mb1log.txt
```
Expected: median ≤ previous. If Step 1 found no safe knob, SKIP this task and record a note. Revert if it breaks bring-up.

- [ ] **Step 5: Commit (only if kept)**

```bash
git add sources/meta-hadron/conf/machine/hadron-ngx012.conf sources/meta-hadron/recipes-bsp/cti-board-support/ scripts/boot-timing/boot_runs.sqlite
git commit -m "perf(boot): silence MB1/BPMP bootloader serial logging"
```

---

## Task 7: Universal win — disable unused DTB nodes

**Files:**
- Create/Modify: a DTB overlay/patch under `sources/meta-hadron/recipes-bsp/cti-board-support/files/` (audio + unused SPI + confirmed-empty PCIe)
- Modify: `sources/meta-hadron/recipes-bsp/cti-board-support/cti-board-support_1.0.bb` (if a new file must be installed/applied)

**Interfaces:**
- Consumes: the CTI board DTB `tegra234-orin-nano-cti-NGX012.dtb` (installed by cti-board-support as `virtual/dtb`).
- Produces: a DTB with specific unused nodes set `status = "disabled"`, cutting kernel probe time. Keep ALL nodes tied to real Hadron peripherals (Ethernet, NVMe, camera, sensors).

- [ ] **Step 1: Enumerate actual peripherals from the running board**

Run:
```bash
ssh ubuntu@192.168.132.100 "sudo dmesg | grep -iE 'pcie|aconnect|spi@|link up'; lspci; ls /proc/device-tree/ | head"
```
Expected: a list of which PCIe controllers have devices, whether audio (`aconnect`) is used, which SPI buses are populated. Only nodes that are provably empty/unused become disable candidates. Document the decision per node.

- [ ] **Step 2: Decompile the DTB and identify target nodes**

Run:
```bash
dtc -I dtb -O dts sources/meta-hadron/recipes-bsp/cti-board-support/files/tegra234-orin-nano-cti-NGX012.dtb -o /tmp/hadron.dts 2>/dev/null
grep -nE 'aconnect@|spi@32|pcie@141e0000' /tmp/hadron.dts
```
Expected: locate the exact nodes. Cross-check against Step 1 — do NOT disable a node with a live device.

- [ ] **Step 3: Create a disabling overlay/patch**

For each confirmed-unused node, set `status = "disabled";`. Prefer a DT overlay `.dtbo` or a `.dts` patch consistent with how cti-board-support already ships DTBs. Example fragment (only for nodes confirmed empty in Steps 1-2):
```dts
&aconnect { status = "disabled"; };
&spi3    { status = "disabled"; };   /* only if unpopulated */
/* pcie@141e0000 only if Step 1 showed it empty */
```
Wire the file into `cti-board-support_1.0.bb` so it is applied to the deployed DTB.

- [ ] **Step 4: Rebuild + verify nodes disabled**

Run: `kas build kas.yml`, then decompile the deployed DTB and confirm `status = "disabled"` on the target nodes only.
Expected: targeted nodes disabled; Ethernet/NVMe/camera/sensor nodes untouched.

- [ ] **Step 5: Flash + measure + hardware sanity**

```bash
# flash, then:
cd scripts/boot-timing
./measure-ping.sh 5 | tee /tmp/opt-dtb.txt
./record.py --label OPT-dtb-nodes --phase 1 --n 5 --sha "$(git rev-parse --short HEAD)" --notes "disable audio/spi/empty-pcie" < /tmp/opt-dtb.txt
# sanity: eth0, nvme, sensors, camera all still present
ssh ubuntu@192.168.132.100 "ip a show eth0; lsblk | grep nvme; ls /dev/iio:* 2>/dev/null; ls /dev/video* 2>/dev/null"
```
Expected: median ≤ previous AND all required peripherals still enumerate. Revert any node whose removal breaks hardware.

- [ ] **Step 6: Commit (only if kept)**

```bash
git add sources/meta-hadron/recipes-bsp/cti-board-support/ scripts/boot-timing/boot_runs.sqlite
git commit -m "perf(boot): disable unused DTB nodes (audio/spi/empty-pcie)"
```

---

## Task 8: New `hadron-image-fastboot` recipe (payload strip)

**Files:**
- Create: `sources/meta-hadron/recipes-core/images/hadron-image-fastboot.bb`

**Interfaces:**
- Consumes: `hadron-image-base.bb` (via `require`); base's `IMAGE_INSTALL:append`.
- Produces: a new build target `hadron-image-fastboot` with CUDA/opencv/full-gstreamer removed, required payload kept. Built via `kas build kas.yml` after overriding `target`, or `KAS_TARGET=hadron-image-fastboot`.

- [ ] **Step 1: Write the fastboot recipe**

Create `sources/meta-hadron/recipes-core/images/hadron-image-fastboot.bb`:
```bitbake
require recipes-core/images/hadron-image-base.bb

SUMMARY = "Hadron NGX012 fastboot image"
DESCRIPTION = "Boots to ICMP-ready fastest. Keeps docker, nvidia-container-toolkit, \
               ffmpeg, pymavlink, wasp; drops CUDA/opencv/full-gstreamer. Heavy \
               services start AFTER ping and are kept off the boot critical path."

# Remove payload not needed at/after ping (added by base via IMAGE_INSTALL:append).
IMAGE_INSTALL:remove = " \
    python3-opencv \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-python \
    gstreamer1.0 \
"
```

- [ ] **Step 2: Build the fastboot image**

Run: `KAS_TARGET=hadron-image-fastboot kas build kas.yml` (or edit `target:` in kas.yml temporarily).
Expected: build succeeds; `hadron-image-fastboot-hadron-ngx012.rootfs.tegraflash.tar.gz` produced. Confirm removed pkgs absent, required pkgs present:
```bash
grep -E "opencv|gstreamer" build/tmp/deploy/images/hadron-ngx012/hadron-image-fastboot-hadron-ngx012.rootfs.manifest || echo "gstreamer/opencv removed OK"
grep -E "docker|ffmpeg|pymavlink|nvidia-container" build/tmp/deploy/images/hadron-ngx012/hadron-image-fastboot-hadron-ngx012.rootfs.manifest
```

- [ ] **Step 3: Flash + measure**

Flash the fastboot tarball, then:
```bash
cd scripts/boot-timing
./measure-ping.sh 5 | tee /tmp/fastboot.txt
./record.py --label fastboot-stripped --phase 2 --n 5 --sha "$(git rev-parse --short HEAD)" --notes "no cuda/opencv/gst" < /tmp/fastboot.txt
```
Expected: median < base median (smaller rootfs / fewer services).

- [ ] **Step 4: Verify required payload still works post-ping**

Run:
```bash
ssh ubuntu@192.168.132.100 "sudo docker info >/dev/null && echo docker-OK; ffmpeg -version | head -1; python3 -c 'import pymavlink; print(\"pymavlink-OK\")'"
```
Expected: `docker-OK`, ffmpeg version, `pymavlink-OK`.

- [ ] **Step 5: Commit**

```bash
git add sources/meta-hadron/recipes-core/images/hadron-image-fastboot.bb scripts/boot-timing/boot_runs.sqlite
git commit -m "feat(image): add hadron-image-fastboot (stripped payload)"
```

---

## Task 9: Kernel defconfig — built-in NIC/NVMe (enables ip= and no-initramfs)

**Files:**
- Modify: `sources/meta-hadron/recipes-kernel/linux/linux-jammy-nvidia-tegra_%.bbappend`
- Create: `sources/meta-hadron/recipes-kernel/linux/linux-jammy-nvidia-tegra/fastboot.cfg`

**Interfaces:**
- Consumes: existing kernel bbappend `SRC_URI` fragment mechanism (see the existing `bmi160.cfg` wiring in `linux-jammy-nvidia-tegra_5.15.bbappend`).
- Produces: kernel with the eth0 NIC driver and NVMe built-in (`=y`), so the `ip=` cmdline (Task 10) and no-initramfs (Task 5) work. **Do this before Task 5/Task 10 if Step 1 of those found `=m`.**

- [ ] **Step 1: Identify the eth0 NIC driver**

Run: `ssh ubuntu@192.168.132.100 "ethtool -i eth0 | grep driver; zcat /proc/config.gz | grep -iE 'CONFIG_STMMAC|CONFIG_R8169|CONFIG_LAN743|CONFIG_IGB|CONFIG_BLK_DEV_NVME'"`
Expected: driver name (e.g. `stmmac`/`r8169`/`lan743x`) and current `=y`/`=m` for it + NVMe. These are the symbols to force `=y`.

- [ ] **Step 2: Write the defconfig fragment**

Create `sources/meta-hadron/recipes-kernel/linux/linux-jammy-nvidia-tegra/fastboot.cfg` with the NIC + NVMe symbols from Step 1 forced built-in, e.g.:
```
CONFIG_BLK_DEV_NVME=y
CONFIG_NVME_CORE=y
# NIC driver identified in Step 1 (replace with the actual symbol):
CONFIG_STMMAC_ETH=y
CONFIG_STMMAC_PLATFORM=y
```

- [ ] **Step 3: Wire the fragment into the bbappend**

In `sources/meta-hadron/recipes-kernel/linux/linux-jammy-nvidia-tegra_%.bbappend`, mirror the existing `.cfg` pattern:
```bitbake
FILESEXTRAPATHS:prepend := "${THISDIR}/linux-jammy-nvidia-tegra:"
SRC_URI += "file://fastboot.cfg"
```
(If a `bbappend` already sets `SRC_URI`/`FILESEXTRAPATHS`, add to it rather than duplicating.)

- [ ] **Step 4: Rebuild + verify config took**

Run: `kas build kas.yml`
Then verify: `find build/tmp -path '*linux-jammy-nvidia-tegra*/.config' -exec grep -E 'CONFIG_BLK_DEV_NVME|<NIC SYMBOL>' {} +`
Expected: symbols now `=y`.

- [ ] **Step 5: Flash + measure + confirm built-in**

```bash
# flash, then:
ssh ubuntu@192.168.132.100 "zcat /proc/config.gz | grep -E 'CONFIG_BLK_DEV_NVME|<NIC SYMBOL>'"
cd scripts/boot-timing && ./measure-ping.sh 5 | tee /tmp/opt-builtin.txt
./record.py --label OPT-builtin-nic-nvme --phase 3 --n 5 --sha "$(git rev-parse --short HEAD)" --notes "NIC+NVMe =y" < /tmp/opt-builtin.txt
```
Expected: symbols `=y`; board boots + pings. (Median may be flat here; the payoff is unlocking Task 10.)

- [ ] **Step 6: Commit**

```bash
git add sources/meta-hadron/recipes-kernel/linux/ scripts/boot-timing/boot_runs.sqlite
git commit -m "feat(kernel): build NIC and NVMe drivers in (enable ip= fastpath)"
```

---

## Task 10: Fastboot image — earliest eth0 via kernel `ip=` cmdline

**Files:**
- Create: `sources/meta-hadron/recipes-core/images/hadron-image-fastboot.bb` append OR a fastboot-only cmdline mechanism (see Step 1)

**Interfaces:**
- Consumes: NIC built-in (Task 9); static config `192.168.132.100/24` on eth0.
- Produces: kernel brings eth0 up with the static IP during kernel init (before systemd-networkd) so ICMP answers earlier. `10-eth0.network` stays as the steady-state config; `:off` disables kernel autoconf handoff cleanly.

Because `UBOOT_EXTLINUX_KERNEL_ARGS` is machine-global, apply the `ip=` arg for the fastboot image only, to avoid changing base/desktop.

- [ ] **Step 1: Add a fastboot-only kernel arg**

Cleanest approach: gate the `ip=` append on the image being built. In `sources/meta-hadron/conf/machine/hadron-ngx012.conf` this is global, so instead add it in the fastboot image recipe via an extlinux regeneration is not available at image scope. Use a dedicated machine include selected only for fastboot builds: create `sources/meta-hadron/recipes-core/images/hadron-image-fastboot.bb` addition:
```bitbake
# Fastboot: bring eth0 up in-kernel (before systemd-networkd) for earliest ICMP.
# NIC driver is built-in (see fastboot.cfg). :off hands steady-state back to networkd.
UBOOT_EXTLINUX_KERNEL_ARGS:append:pn-hadron-image-fastboot = " ip=192.168.132.100::192.168.132.1:255.255.255.0::eth0:off"
```
If `:pn-` override on this var does not take effect (it is consumed by the kernel/extlinux recipe, not the image), fall back to a `MACHINEOVERRIDES`-gated include or a separate `hadron-ngx012-fastboot` machine that inherits the base machine and only adds the `ip=` arg. Verify which mechanism actually lands the arg in Step 3.

- [ ] **Step 2: Rebuild fastboot image**

Run: `KAS_TARGET=hadron-image-fastboot kas build kas.yml`
Expected: build succeeds.

- [ ] **Step 3: Verify the arg is in the fastboot extlinux only**

Run: `find build/tmp -name extlinux.conf -exec grep -l 'ip=192.168.132.100' {} +`
Expected: present for the fastboot boot.img; confirm base image extlinux does NOT carry it (build base separately and diff if unsure).

- [ ] **Step 4: Flash + measure + check no IP flap**

```bash
# flash fastboot, then:
cd scripts/boot-timing && ./measure-ping.sh 5 | tee /tmp/opt-ip.txt
./record.py --label OPT-ip-cmdline --phase 2 --n 5 --sha "$(git rev-parse --short HEAD)" --notes "kernel ip= early eth0" < /tmp/opt-ip.txt
# confirm networkd still owns the address afterwards, single address, no dup
ssh ubuntu@192.168.132.100 "ip -o addr show eth0; networkctl status eth0 | head"
```
Expected: median < previous fastboot number; exactly one `192.168.132.100/24` on eth0; networkd reports the link `configured`. Revert if the address flaps or duplicates.

- [ ] **Step 5: Commit (only if kept)**

```bash
git add sources/meta-hadron/ scripts/boot-timing/boot_runs.sqlite
git commit -m "perf(fastboot): bring eth0 up in-kernel via ip= for earliest ICMP"
```

---

## Task 11: Final report & documentation

**Files:**
- Create: `docs/superpowers/specs/2026-08-20-fastboot-results.md`

**Interfaces:**
- Consumes: all `boot_runs` rows.
- Produces: a results table (baseline → each kept optimization → final), and a note of skipped/reverted experiments.

- [ ] **Step 1: Dump the results table**

Run: `python3 -c "import sqlite3;[print(r) for r in sqlite3.connect('scripts/boot-timing/boot_runs.sqlite').execute('select experiment_label,phase,median_ms,min_ms,notes from boot_runs order by id')]"`
Expected: full experiment history.

- [ ] **Step 2: Write the results doc**

Create `docs/superpowers/specs/2026-08-20-fastboot-results.md` with: baseline median, per-optimization delta, final base median, final fastboot median, and a list of reverted/skipped experiments with reasons. (Fill with the real recorded numbers — no placeholders.)

- [ ] **Step 3: Update the copilot-instructions flashing note**

Add a short "Building the fastboot image" subsection to `.github/copilot-instructions.md` documenting `KAS_TARGET=hadron-image-fastboot kas build kas.yml`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-20-fastboot-results.md .github/copilot-instructions.md
git commit -m "docs(fastboot): record boot-till-ping results and fastboot build note"
```

---

## Self-Review Notes

- **Spec coverage:** Phase 0 harness → Tasks 1-2. Phase 1 universal wins → Tasks 3-7 (extlinux, quiet, no-initramfs, bootloader log, DTB). Phase 2 fastboot image → Tasks 8, 10. Phase 3 kernel defconfig → Task 9. Rejected busybox → documented in spec, no task (correct). Results/success-criteria → Task 11. All spec sections mapped.
- **Ordering dependency:** Task 5 (no-initramfs) and Task 10 (`ip=`) require NVMe/NIC built-in; Task 9 supplies that. If Task 5/10 Step 1 finds `=m`, run Task 9 first. This is called out inline in each affected task.
- **Placeholder scan:** The only intentional "confirm the real value" steps are Task 6 (meta-tegra log var name) and Task 9/10 (actual NIC symbol + arg-injection mechanism) — these are hardware/BSP facts that MUST be read from the pinned tree at execution time, and each has an explicit discovery step rather than a hand-waved value.
- **Consistency:** `boot_runs` schema identical in Task 1 SQL and `record.py`. `measure-ping.sh` output contract (`MEDIAN_MS=`/`MIN_MS=`) consumed consistently by `record.py`. Image/recipe names consistent (`hadron-image-fastboot`).
