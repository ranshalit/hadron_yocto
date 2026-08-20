# Fastboot: Boot-till-ping Optimization — Design

**Date:** 2026-08-20
**Branch:** `fastboot_opt`
**Machine:** `hadron-ngx012` (Jetson Orin Nano 4GB, p3767-0003, ConnectTech Hadron NGX012)
**Status:** Design approved — pending implementation plan

---

## 1. Goal & Success Metric

Reduce **power-on → first ICMP ping reply** on the device's static address
`192.168.132.100` (eth0). "Ping ready" = the device answers ICMP echo; no
higher-level service (SSH, app) is required to be up at that instant.

- **Baseline:** unknown — to be measured in Phase 0 before any change.
- **Target:** no hard number; goal is a reproducible, measurable reduction from
  the Phase-0 baseline, keeping base + desktop images fully functional.

ICMP replies as soon as the **kernel is up and eth0 has its IP**. Heavy payload
(docker, nvidia-container-toolkit, ffmpeg, pymavlink, the application) starts
*after* ping and must be kept off the ICMP critical path — it does not need to be
removed, only de-gated from early boot.

---

## 2. Boot Chain (where the time goes)

```
Power on
  → QSPI firmware: MB1 → MB2 (BCT) → BPMP → TOS → UEFI      (bootloader, serial logging costs time)
  → UEFI → extlinux menu (ESP)                              (menu TIMEOUT costs time)
  → kernel (boot.img on NVMe) + CTI DTB                     (driver probe, verbosity)
  → systemd                                                 (unit ordering)
  → systemd-networkd brings eth0 up with static IP          (← ICMP answers here today)
  → docker / app / heavy services                           (AFTER ping — keep off critical path)
```

The earliest possible ICMP answer is bounded by kernel bring-up + NIC driver +
IP assignment. The single largest ICMP-specific lever is assigning the static IP
via the **kernel `ip=` cmdline** so the interface answers before userspace
(systemd-networkd) even runs — this requires the NIC driver to be **built-in**,
not a loadable module (verified in Phase 0).

---

## 3. Strategy — Hybrid (measured, phased)

Per decision: apply **universal, risk-free wins to the base image** (so base +
desktop + fastboot all benefit) AND add a dedicated **`hadron-image-fastboot`**
image for aggressive service/payload stripping. The **desktop image stays
functional** and only inherits the universal wins — no fastboot stripping.

Kernel defconfig changes are **permitted** where they measurably help (built-in
NIC/NVMe, strip unused drivers).

### Phase 0 — Measurement harness (do first, establish baseline)

Location: `scripts/boot-timing/`.

- **Host-side real number** (`measure-ping.sh`): use the **zup power-supply
  skill** to power-cycle the board, then run a tight host `ping` loop against
  `192.168.132.100`; timestamp the first reply. Repeat N runs, report **median**
  (power-on → ICMP ms). This is the authoritative metric.
- **On-device per-stage breakdown**: capture `systemd-analyze time`,
  `systemd-analyze blame`, `systemd-analyze critical-chain`, and `dmesg`
  timestamps to attribute cost to bootloader vs kernel vs userspace. (Note:
  `systemd-analyze` misses pre-kernel/bootloader time — host ping covers the
  whole chain.)
- **Record results** to the session SQLite DB, table `boot_runs`
  (`experiment_label`, `phase`, `median_ms`, `n_runs`, `notes`, `git_sha`).
  Every experiment is kept or discarded against the measured number.

### Phase 1 — Universal wins → base image (`hadron-image-base` / machine conf)

Each item measured individually; discard any that regresses or breaks hardware.

- **extlinux menu timeout:** `UBOOT_EXTLINUX_TIMEOUT = "0"` (menu never used;
  recovery is via reflash).
- **Quiet kernel:** append `quiet loglevel=0` to `UBOOT_EXTLINUX_KERNEL_ARGS`
  (keep the existing `console=ttyTHS1,115200 console=tty0`; `dmesg` remains
  available post-boot for diagnostics).
- **Drop boot initramfs:** boot `root=/dev/nvme0n1p1` directly (rootfs always on
  NVMe). Requires NVMe driver built-in — verified in Phase 0.
- **Bootloader serial-log silence:** MB1/BPMP serial logging off via meta-tegra
  flash BCT knobs (e.g. `TEGRA_MB1_LOG_LEVEL`, BPMP serial logging) — exact
  variable names verified against the pinned meta-tegra commit before use.
- **DTB node disable:** disable clearly-unused nodes (audio `aconnect@`, unused
  `spi@`, confirmed-empty PCIe controllers) in the CTI DTB. Conservative,
  per-node verified against the hadron DTB and its actual peripherals (camera,
  monitoring HW, Ethernet, NVMe must stay). Modeled on the lumen `opt_2.md`
  analysis but re-verified for the Hadron carrier — the boards differ.

### Phase 2 — `hadron-image-fastboot` (new recipe)

- `require recipes-core/images/hadron-image-base.bb`, then trim payload **not**
  needed at/after ping. **Remove:** CUDA stack, opencv, full gstreamer plugin
  set. **Keep:** docker-moby, nvidia-container-toolkit, ffmpeg, pymavlink,
  wasp-version, hadron-network, sshd, serial symlinks, sensor config.
  (`wasp-version` = a trivial version-stamp file `/etc/wasp/version/version.txt`,
  no runtime cost.)
- **De-gate heavy services from the ICMP path:** ensure `docker.service` and the
  application unit are ordered so they do not block early boot / `network.target`
  reaching ping. They boot *after* ICMP is answered.
- **Earliest eth0 via kernel cmdline** (fastboot image only): if the NIC driver
  is built-in, add `ip=192.168.132.100::192.168.132.1:255.255.255.0::eth0:off`
  so the interface answers ICMP before systemd-networkd runs. Keep
  `10-eth0.network` as the steady-state config (`:off` disables kernel autoconf,
  networkd takes over cleanly). If the NIC is a module, either build it in
  (Phase 3) or fall back to the networkd-only path.

### Phase 3 — Kernel defconfig (optional, measured)

- Build **NIC + NVMe built-in** if currently modules (enables `ip=` and
  initramfs-free boot).
- Strip obviously-unused drivers to cut kernel probe time.
- Gated strictly behind measured benefit; the **desktop image must still boot**.

---

## 4. Files Touched

| File | Change | Phase |
|---|---|---|
| `scripts/boot-timing/` | new measurement harness (zup + ping loop + on-device) | 0 |
| `sources/meta-hadron/conf/machine/hadron-ngx012.conf` | extlinux timeout, quiet cmdline, no-initramfs, BCT log vars | 1 |
| `sources/meta-hadron/recipes-bsp/cti-board-support/files/*` (DTB) | disable unused DTB nodes | 1 |
| `sources/meta-hadron/recipes-core/images/hadron-image-fastboot.bb` | new fastboot image recipe | 2 |
| `sources/meta-hadron/recipes-kernel/linux/*` (defconfig fragment) | built-in NIC/NVMe, strip drivers | 3 |
| `kas.yml` (optional) | fastboot build target / instructions | 2 |

---

## 5. Reference Material: lumen repo

`/media/ranshal/jetson/lumen` is a **sibling Yocto BSP for a different Orin board
(different carrier, different requirements, busybox init vs. Hadron's systemd)**.
It is NOT directly reusable, but its **git history and docs are a tested
idea-source** for boot optimization and should be consulted for candidates
(re-verified for Hadron before adopting):

- **Docs:** `docs/boot-optimize.md`, `docs/plan_opt.md`,
  `docs/opt_2.md` (this one lists concrete tested tweaks — extlinux TIMEOUT=0,
  MB1/BPMP serial silence, initramfs elimination, DTB/PCIe node disable — with
  per-item savings; references an experiment branch that took another Orin from
  ~30s to ~6s), `docs/boot_before_kernel_opt.txt`.
- **Boot-opt git branches (local):** `optimize_boot_v1`, `boot-opt/eth-instrument`.
- **Tested fixes in history worth reading:**
  - `8521076` "udev: drop r8168->eth0 rename rule (fixes boot-to-ping regression)"
  - `b257bd4` "Fix 120s boot freeze: move usb2-0 host-mode switch out of udev"
- **Measurement reference:** `scripts/validate-boot.py` (SSH/serial boot-health
  validator, incl. eth0 link + ping checks) — pattern reusable for the Hadron
  harness.

> ⚠️ Caveat: lumen uses **busybox init** (`INIT_MANAGER = "mdev-busybox"`), so its
> `inittab`/`rcS` deferral patterns do NOT translate to Hadron, which uses
> **systemd**. Bootloader/kernel/DTB-level ideas DO translate; init-system ideas
> must be re-expressed as systemd unit ordering/masking.

---

## 6. Success Criteria

- A reproducible **median power-on → ICMP** number, measurably lower than the
  Phase-0 baseline.
- `hadron-image-base` and `hadron-image-desktop` still boot and function.
- `hadron-image-fastboot` boots to ping fastest while still able to bring up
  docker + ffmpeg + pymavlink + the application *after* ping.

## 7. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| DTB/kernel trim breaks a peripheral | Measure each change on the real board via zup loop; keep/discard individually; one git commit per experiment for easy revert. |
| `ip=` cmdline conflicts with systemd-networkd | Use `:off` autoconf; keep `10-eth0.network` for steady state; verify no address flap. |
| NIC/NVMe is a module → `ip=`/no-initramfs impossible | Phase 0 verifies; Phase 3 builds them in, else fall back to networkd path. |
| Bootloader BCT log vars wrong for pinned meta-tegra | Verify exact variable names against the pinned meta-tegra commit before applying. |
| Optimization helps ICMP but delays a needed service | ICMP metric is explicit; app/docker readiness validated separately post-ping. |
