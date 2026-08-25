#!/usr/bin/env bash
#
# flash_eth_initrd.sh — Flash a Jetson Orin over Ethernet only (no USB, no
# recovery mode), from the running OS, using the eth-initrd-flash skill.
#
# It drives the bundled skill scripts to:
#   Phase 1  build + boot a NON-DESTRUCTIVE validator initramfs (proves boot path)
#   Stage    upload the partition image(s) to the device and verify their sha256
#   Phase 2  build + boot a flasher initramfs that, from RAM, dd's each staged
#            image onto its NVMe partition (the single point of no return)
#
# ── SCOPE (what gets flashed) ────────────────────────────────────────────────
# This flasher writes NVMe partition *contents* by partlabel. Two scopes:
#
#   --full-nvme   (DEFAULT) APP(rootfs) + ESP(+esp_alt) + A/B kernel + A/B
#                 kernel-dtb. This is the full NVMe content set Lumen's boot uses,
#                 matching what NVIDIA's recovery-mode flash would put on NVMe —
#                 MINUS the MBR/GPT (never rewritten: the layout is identical to
#                 the build, and the GPT is the one unrecoverable-if-wrong write
#                 with no USB-recovery net) and MINUS QSPI (the on-board UEFI has
#                 capsule support compiled out — see docs/todo section 5).
#   --rootfs-only flash ONLY APP (/dev/nvme0n1p1). The original, smallest-blast
#                 behavior; keeps every boot-critical partition untouched.
#
# Why not the GPT / QSPI? Because we run from the LIVE OS with no recovery
# fallback: corrupting the partition table or bootloader would brick the board
# with no way back. Writing partition *contents* (not the table) keeps the boot
# chain (QSPI → UEFI → ESP → extlinux → rootfs) intact as a safety net.
#
# Forward-compat with signed images: each partition's source file is declared in
# one place (the PARTSPEC table below). When you move to secure boot, swap the
# raw filenames for the signed artifacts (e.g. boot_sigheader.img.encrypt) — the
# flasher writes bytes, so the mechanism does not change. (You will also need one
# recovery-mode flash to install the matching signed QSPI bootloader.)
#
# ── SAFETY ───────────────────────────────────────────────────────────────────
# Nothing is written to any partition until Phase 2, which (per partition)
# happens only after: a successful boot-through test (optional Phase 1), an
# on-device sha256 check, an in-RAM sha256 re-check of EVERY image (the GATE),
# and a capacity check. The script PAUSES for confirmation before Phase 2.
# The flasher writes the small boot-critical partitions first and the large
# APP/rootfs LAST, so the longest power-exposed write lands on the partition that
# can simply be re-flashed (QSPI+ESP stay intact if it fails). Do NOT cut power
# during Phase 2.
#
# LUMEN NOTE: Phase 1 is SKIPPED by default (Lumen builds NVMe+PCIe into the
# kernel and never boots with an initramfs; the validator's switch_root path is
# unrepresentative and can reboot-loop). Phase 2 does NOT switch_root, is
# self-healing, and the flashed image carries its own clean extlinux.
#
# Usage:
#   ./flash_eth_initrd.sh                 # FULL NVMe set, confirm before writes
#   ./flash_eth_initrd.sh --rootfs-only   # only APP/rootfs (old behavior)
#   ./flash_eth_initrd.sh --yes           # skip the pre-write confirmation prompt
#   ./flash_eth_initrd.sh --image PATH    # override the rootfs image to flash
#   ./flash_eth_initrd.sh --with-phase1   # also run the Phase 1 boot-path validator
#   ./flash_eth_initrd.sh --phase1-only   # build+validate boot path, then stop
#
set -euo pipefail

# ───────────────────────── configuration (edit to taste) ─────────────────────
# Credentials: prefer explicit SSH_USER/SSH_PASS, else fall back to the repo's
# canonical DEVICE_SSH_USER/DEVICE_SSH_PASS (.env), else root/root.
_envget(){ [ -f .env ] && grep -m1 "^$1=" .env | cut -d= -f2- || true; }
DEVICE_IP="${DEVICE_IP:-$(_envget DEVICE_IP)}"; DEVICE_IP="${DEVICE_IP:-192.168.132.100}"
SSH_USER="${SSH_USER:-${DEVICE_SSH_USER:-$(_envget DEVICE_SSH_USER)}}"; SSH_USER="${SSH_USER:-root}"
SSH_PASS="${SSH_PASS:-${DEVICE_SSH_PASS:-$(_envget DEVICE_SSH_PASS)}}"; SSH_PASS="${SSH_PASS:-root}"

ROOT_DEV="${ROOT_DEV:-/dev/nvme0n1p1}"          # rootfs partition (read source from here; APP target)
EXTLINUX="${EXTLINUX:-/boot/extlinux/extlinux.conf}"
MODULES="${MODULES:-auto}"                       # initrd storage modules: "auto" = probe device (Lumen NVMe is built-in -> none); "" = force none; "m1 m2" = explicit list
KERNEL_DTB="${KERNEL_DTB:-}"                      # kernel devicetree filename; "" = auto-derive from the tegraflash package (per-machine; do NOT hardcode)

# rootfs image: auto-discover *.rootfs.ext4 under build/tmp/deploy/images/**, or set IMAGE=
IMAGES_BASE="${IMAGES_BASE:-build/tmp/deploy/images}"
if [ -z "${IMAGE:-}" ]; then
  mapfile -t _candidates < <(find "$IMAGES_BASE" -name "*.rootfs.ext4" 2>/dev/null | sort)
  case "${#_candidates[@]}" in
    0) IMAGE="" ;;
    1) IMAGE="${_candidates[0]}" ;;
    *) IMAGE="$(ls -t "${_candidates[@]}" | head -1)"
       echo "WARNING: multiple rootfs images found; using newest: $IMAGE"
       echo "  Set IMAGE=<path> to choose a specific one." ;;
  esac
fi

# tegraflash package (source of esp.img / boot.img / kernel-dtb), auto-discovered.
TEGRAFLASH_TGZ="${TEGRAFLASH_TGZ:-}"
if [ -z "$TEGRAFLASH_TGZ" ]; then
  TEGRAFLASH_TGZ="$(find "$IMAGES_BASE" -name "*.tegraflash.tar.gz" 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1)"
fi

SERIAL_PORT="${SERIAL_PORT:-/dev/ttyUSB1}"       # serial observation/recovery channel ("" to skip)

SKILLS_DIR="${SKILLS_DIR:-$HOME/.copilot/skills}"
ETH_SKILL="$SKILLS_DIR/eth-initrd-flash/scripts"
SERIAL_SKILL="$SKILLS_DIR/serial-console/scripts/serial_session.py"
ETH_TRANSFER="$SKILLS_DIR/ethernet-console/scripts/eth_transfer.py"
MULTI_INIT="${MULTI_INIT:-$(dirname "$(readlink -f "$0")")/init-phase2-multi.sh}"

WORK="${WORK:-/tmp/eth-flash}"
# ──────────────────────────────────────────────────────────────────────────────

ASSUME_YES=0; PHASE1_ONLY=0; SKIP_PHASE1=1; SCOPE="full-nvme"; STAGE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --image) IMAGE="$2"; shift 2 ;;
    --full-nvme) SCOPE="full-nvme"; shift ;;
    --rootfs-only) SCOPE="rootfs-only"; shift ;;
    --stage-only) STAGE_ONLY=1; shift ;;   # non-destructive: stage+verify+build initrd, then STOP (no writes)
    --phase1-only) PHASE1_ONLY=1; SKIP_PHASE1=0; shift ;;
    --with-phase1) SKIP_PHASE1=0; shift ;;
    --skip-phase1) SKIP_PHASE1=1; shift ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)
dssh(){ SSHPASS="$SSH_PASS" sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_USER@$DEVICE_IP" "$@" 2>/dev/null | grep -v "Permanently added" || true; }
dscp(){ SSHPASS="$SSH_PASS" sshpass -e scp "${SSH_OPTS[@]}" "$@" 2>/dev/null | grep -v "Permanently added" || true; }
[ "$SSH_USER" = "root" ] && SUDO="" || SUDO="sudo -n "
push_boot(){
  local src="$1" dst="$2"; local tmp="/tmp/$(basename "$dst").$$"
  dscp "$src" "$SSH_USER@$DEVICE_IP:$tmp"
  dssh "${SUDO}mv $tmp $dst && ${SUDO}chown root:root $dst"
}
ssh_ready(){ SSHPASS="$SSH_PASS" sshpass -e ssh -o ConnectTimeout=5 "${SSH_OPTS[@]}" "$SSH_USER@$DEVICE_IP" "echo __UP__" 2>/dev/null | grep -q __UP__; }
# Poll SSH, returning the instant the board answers. $1 = max attempts. Each
# attempt costs up to ~5s connect-timeout (only when the host is reachable-but-
# silent; a downed link fails fast) + 5s sleep, so the wall-clock cap is roughly
# n*10s worst case, but a board that comes back early returns early. Prints a
# heartbeat (elapsed sleep seconds) every ~30s so a long wait isn't silent.
wait_ssh(){ local n="${1:-40}" k=0; for _ in $(seq 1 "$n"); do ssh_ready && { [ "$k" -gt 0 ] && echo; return 0; }; k=$((k+1)); [ $((k % 6)) -eq 0 ] && printf ' [%ds]' "$((k*5))"; sleep 5; done; echo; return 1; }
export DEVICE_IP DEVICE_SSH_USER="$SSH_USER" DEVICE_SSH_PASS="$SSH_PASS"

serial_up=0
serial(){ [ -n "$SERIAL_PORT" ] || return 0; SERIAL_BOOT_PORT="$SERIAL_PORT" SERIAL_LINUX_PORT="$SERIAL_PORT" python "$SERIAL_SKILL" "$@"; }

# ───────────────────────── Step 0: preflight ─────────────────────────
log "Step 0: preflight  (scope: $SCOPE)"
for t in sshpass scp ssh gzip sha256sum cpio readelf python3 tar; do command -v "$t" >/dev/null || die "missing host tool: $t"; done
[ -f "$IMAGE" ] || die "rootfs image not found: $IMAGE"
RAW_IMG="$(readlink -f "$IMAGE")"
[ -f "$MULTI_INIT" ] || die "multi-partition init template not found: $MULTI_INIT"
if [ "$SCOPE" = "full-nvme" ]; then
  [ -n "$TEGRAFLASH_TGZ" ] && [ -f "$TEGRAFLASH_TGZ" ] || die "tegraflash package not found (needed for ESP/kernel/dtb). Set TEGRAFLASH_TGZ=<path> or use --rootfs-only"
  TEGRAFLASH_TGZ="$(readlink -f "$TEGRAFLASH_TGZ")"
fi
# Some networks block ICMP while SSH is allowed; treat ping as best-effort only.
if ! ping -c1 -W2 "$DEVICE_IP" >/dev/null; then
  echo "WARNING: ping to $DEVICE_IP failed; continuing with SSH connectivity check."
fi
ssh-keygen -R "$DEVICE_IP" -f "${HOME}/.ssh/known_hosts" 2>/dev/null || true
ssh_ready || die "cannot SSH as $SSH_USER@$DEVICE_IP (check creds / .env DEVICE_SSH_USER/PASS)"
echo "rootfs image : $IMAGE  ($(du -h "$RAW_IMG" | cut -f1))"
[ "$SCOPE" = "full-nvme" ] && echo "tegraflash   : $TEGRAFLASH_TGZ"
mkdir -p "$WORK"

# ───────────────────────── Step 1: recon ─────────────────────────
log "Step 1: recon"
MEM_AVAIL_KB="$(dssh "sed -n 's/^MemAvailable:[ \t]*\([0-9]*\).*/\1/p' /proc/meminfo")"
[ -n "$MEM_AVAIL_KB" ] || MEM_AVAIL_KB=0
echo "device MemAvailable : $((MEM_AVAIL_KB/1024)) MiB"
# /tmp is tmpfs and bounds the chunk-reassembly buffer used by eth_transfer.py.
# If /tmp is smaller than RAM, use it as the gzip threshold so a sparse raw image
# bigger than /tmp gets compressed on the host before upload.
TMP_AVAIL_KB="$(dssh "df -kP /tmp | awk 'NR==2{print \$4}'" | tr -dc '0-9')"
[ -n "$TMP_AVAIL_KB" ] || TMP_AVAIL_KB=0
echo "device /tmp free    : $((TMP_AVAIL_KB/1024)) MiB"
if [ "$TMP_AVAIL_KB" -gt 0 ] && [ "$TMP_AVAIL_KB" -lt "$MEM_AVAIL_KB" ]; then
  MEM_AVAIL_KB="$TMP_AVAIL_KB"
fi
dssh "mount | grep ' / '" || true

# Auto-detect storage modules for the flasher initrd. "auto" probes the device and
# bundles the NVMe/PCIe chain ONLY where those drivers are loadable modules (Lumen
# builds them into the kernel -> nothing to bundle; other machines may build them
# as modules). MODULES="" forces none; MODULES="m1 m2" forces an explicit list.
if [ "$MODULES" = "auto" ]; then
  MODULES="$(dssh '
    is_mod(){ f=$(modinfo -F filename "$1" 2>/dev/null | tr -d "\r"); [ -n "$f" ] && [ "$f" != "(builtin)" ]; }
    out=""
    for m in phy-tegra194-p2u pcie-tegra194 nvme_core nvme; do
      is_mod "$m" && out="$out $m"
    done
    echo $out
  ' | tr -d '\r' | xargs || true)"
  if [ -n "$MODULES" ]; then
    echo "storage modules     : loadable -> initrd will bundle: $MODULES"
  else
    echo "storage modules     : built into kernel (Lumen-style) -> none bundled"
  fi
fi

# Staging dir on the device's rootfs (read back by the initrd after mounting root).
if [ "$SSH_USER" = "root" ]; then STAGE_DIR="/flash"; else STAGE_DIR="/home/$SSH_USER/flash"; fi
dssh "mkdir -p $STAGE_DIR"

# Resolve a partlabel -> /dev/nvme0n1pN on the device.
resolve_partlabel(){ dssh "readlink -f /dev/disk/by-partlabel/$1" | tr -d '\r'; }

# ───────────────────────── Step 2: extract source images ─────────────────────────
SRC="$WORK/src"; mkdir -p "$SRC"
if [ "$SCOPE" = "full-nvme" ]; then
  log "Step 2: extract ESP / kernel / dtb from tegraflash package"
  # The kernel devicetree is the .dtb argument on the tegra-flash-helper.sh command
  # line in doexternal.sh — authoritative and per-machine (e.g. Lumen/Orin
  # tegra234-p3768-...-nv-super.dtb, hadron tegra234-orin-nano-cti-NGX012.dtb). The
  # many tegra234-bpmp-*.dtb in the package are NOT on that line, so this picks the
  # one real kernel dtb. Override with KERNEL_DTB=<name> if ever needed.
  DTB_NAME="$KERNEL_DTB"
  [ -n "$DTB_NAME" ] || DTB_NAME="$(tar xzOf "$TEGRAFLASH_TGZ" doexternal.sh 2>/dev/null | grep -oE '[A-Za-z0-9._+-]+\.dtb' | head -1)"
  [ -n "$DTB_NAME" ] || die "could not determine kernel DTB from tegraflash package (no .dtb on doexternal.sh's flash-helper line). Set KERNEL_DTB=<name>."
  ( cd "$SRC" && tar xzf "$TEGRAFLASH_TGZ" boot.img esp.img "$DTB_NAME" )
  [ -f "$SRC/boot.img" ] || die "boot.img missing from tegraflash package"
  [ -f "$SRC/esp.img" ]  || die "esp.img missing from tegraflash package"
  [ -f "$SRC/$DTB_NAME" ] || die "$DTB_NAME missing from tegraflash package"
  cp "$SRC/$DTB_NAME" "$SRC/kernel.dtb"
  echo "  esp.img    $(du -h "$SRC/esp.img"|cut -f1)"
  echo "  boot.img   $(du -h "$SRC/boot.img"|cut -f1)"
  echo "  kernel.dtb $(du -h "$SRC/kernel.dtb"|cut -f1)  ($DTB_NAME)"
fi

# ───────────────────────── Step 3: build the partition table ─────────────────────────
# PARTSPEC rows: "LABEL  SOURCE_FILE  PARTLABEL". Order = write order; APP LAST.
# To move to signed images later, change SOURCE_FILE here (e.g. a signed variant).
log "Step 3: build partition table"
declare -a PARTSPEC=()
if [ "$SCOPE" = "full-nvme" ]; then
  PARTSPEC+=("esp           $SRC/esp.img    esp")
  PARTSPEC+=("esp_alt       $SRC/esp.img    esp_alt")
  PARTSPEC+=("A_kernel      $SRC/boot.img   A_kernel")
  PARTSPEC+=("B_kernel      $SRC/boot.img   B_kernel")
  PARTSPEC+=("A_kernel_dtb  $SRC/kernel.dtb A_kernel-dtb")
  PARTSPEC+=("B_kernel_dtb  $SRC/kernel.dtb B_kernel-dtb")
fi
PARTSPEC+=("APP           $RAW_IMG        APP")   # rootfs LAST (largest, recoverable-by-reflash)

# Resolve targets, sizes, shas; decide raw-vs-gz staging per file; stage; verify.
declare -a M_LABEL M_TARGET M_STAGEREL M_SHA M_COMP M_SRC
for row in "${PARTSPEC[@]}"; do
  read -r label src plabel <<<"$row"
  tgt="$(resolve_partlabel "$plabel")"
  [ -n "$tgt" ] || die "could not resolve partition label '$plabel' on device"
  [ -f "$src" ] || die "source image for $label not found: $src"
  M_LABEL+=("$label"); M_TARGET+=("$tgt"); M_SRC+=("$src")
done

# ───────────────────────── Step 4: stage every image + verify ─────────────────────────
log "Step 4: stage images on device + verify sha256"
stage_one(){ # $1 label  $2 src  $3 target_dev  -> sets globals: _SHA _STAGEREL _COMP
  local label="$1" src="$2" tgt="$3"
  local raw_bytes raw_sha comp stage_local stage_rel base
  raw_bytes="$(stat -c %s "$src")"
  base="$(basename "$src")"
  echo "  [$label] $base  ($((raw_bytes/1024/1024)) MiB)  -> $tgt"
  # capacity pre-check (host-side, before staging)
  local tsec tbytes
  tsec="$(dssh "cat /sys/class/block/$(basename "$tgt")/size" | tr -dc '0-9')"
  if [ -n "$tsec" ] && [ "$tsec" -gt 0 ] 2>/dev/null; then
    tbytes=$((tsec*512))
    [ "$raw_bytes" -le "$tbytes" ] || die "$label image ${raw_bytes}B > target ${tbytes}B ($tgt) — disk untouched"
  fi
  raw_sha="$(sha256sum "$src" | cut -d' ' -f1)"
  # compress only when the raw image won't fit in device RAM (the big rootfs)
  if [ "$raw_bytes" -gt $(( MEM_AVAIL_KB * 1024 )) ] && [ "$MEM_AVAIL_KB" -gt 0 ]; then
    comp=1; stage_rel="$STAGE_DIR/${label}.img.gz"; stage_local="$WORK/${label}.img.gz"
    if [ ! -f "$stage_local" ] || [ "$(cat "$stage_local.rawsha" 2>/dev/null)" != "$raw_sha" ]; then
      echo "    gzipping (raw > device RAM)..."; gzip -1 -c "$src" > "$stage_local"
      printf '%s\n' "$raw_sha" > "$stage_local.rawsha"
    fi
  else
    comp=0; stage_rel="$STAGE_DIR/${label}.img"; stage_local="$src"
  fi
  # skip upload if device already holds a correct staged copy
  local got
  if [ "$comp" = 1 ]; then
    got="$(dssh "test -f $stage_rel && gzip -t $stage_rel && gunzip -c $stage_rel | sha256sum" | tail -1 | cut -d' ' -f1)"
  else
    got="$(dssh "test -f $stage_rel && sha256sum $stage_rel" | tail -1 | cut -d' ' -f1)"
  fi
  if [ "$got" = "$raw_sha" ]; then
    echo "    already staged (sha ok), skipping upload"
  else
    python "$ETH_TRANSFER" upload --local "$stage_local" --remote "$stage_rel" \
      --ip "$DEVICE_IP" --user "$SSH_USER" --password "$SSH_PASS" --chunk-size 32 2>&1 | grep -v "Permanently added" | tail -2
    if [ "$comp" = 1 ]; then
      got="$(dssh "gzip -t $stage_rel && gunzip -c $stage_rel | sha256sum" | tail -1 | cut -d' ' -f1)"
    else
      got="$(dssh "sha256sum $stage_rel" | tail -1 | cut -d' ' -f1)"
    fi
    [ "$got" = "$raw_sha" ] || die "$label staged sha mismatch: got $got want $raw_sha"
  fi
  _SHA="$raw_sha"; _STAGEREL="$stage_rel"; _COMP="$comp"
}

i=0
while [ $i -lt ${#M_LABEL[@]} ]; do
  stage_one "${M_LABEL[$i]}" "${M_SRC[$i]}" "${M_TARGET[$i]}"
  M_SHA+=("$_SHA"); M_STAGEREL+=("$_STAGEREL"); M_COMP+=("$_COMP")
  i=$((i+1))
done

# ───────────────────────── Step 5: build the multi-partition flasher initrd ─────────────────────────
log "Step 5: build flasher initramfs (manifest of ${#M_LABEL[@]} partition(s))"
MANIFEST=""
i=0
while [ $i -lt ${#M_LABEL[@]} ]; do
  MANIFEST+="add_entry ${M_LABEL[$i]} ${M_TARGET[$i]} ${M_STAGEREL[$i]} ${M_SHA[$i]} ${M_COMP[$i]}"$'\n'
  i=$((i+1))
done
# substitute @ROOT_DEV@/@EXTLINUX@ then inject the manifest block at @MANIFEST@
sed -e "s#@ROOT_DEV@#$ROOT_DEV#g" -e "s#@EXTLINUX@#$EXTLINUX#g" "$MULTI_INIT" > "$WORK/init.phase2-multi.tmpl"
awk -v mf="$MANIFEST" '{ if ($0 ~ /^@MANIFEST@[ \t]*$/) { printf "%s", mf } else { print } }' \
    "$WORK/init.phase2-multi.tmpl" > "$WORK/init.phase2-multi"
echo "  manifest:"; sed 's/^/    /' <<<"$MANIFEST"
bash "$ETH_SKILL/build_initramfs.sh" --init "$WORK/init.phase2-multi" --out "$WORK/initrd-flasher.cpio.gz" --modules "$MODULES" 2>&1 | grep -vE "Permanently added|^\[build\]" || true
ls -l "$WORK/initrd-flasher.cpio.gz"

if [ "$STAGE_ONLY" = 1 ]; then
  log "STAGE-ONLY: all images staged + verified, flasher initramfs built. NO partitions written."
  echo "Staged on device under: $STAGE_DIR"
  echo "Flasher initramfs:       $WORK/initrd-flasher.cpio.gz"
  echo "Re-run without --stage-only (and confirm YES) to actually flash."
  exit 0
fi

# bring up serial observation channel
if [ -n "$SERIAL_PORT" ]; then
  serial daemon status 2>/dev/null | grep -q running || { serial daemon start >/dev/null 2>&1 && serial_up=1; }
  echo "serial log: tail -f /tmp/serial.log"
fi

reboot_and_wait(){ dssh "${SUDO}sync; ${SUDO}reboot" || true; sleep 10; serial capture --port linux --timeout 120 >/dev/null 2>&1 || true; wait_ssh 48 || echo "WARNING: SSH not back yet — check /tmp/serial.log"; grep -aiE "$1" /tmp/serial.log | tail -5 || true; }

# ───────────────────────── Step 6: optional Phase 1 (NON-DESTRUCTIVE) ─────────────────────────
if [ "$SKIP_PHASE1" = 0 ]; then
  log "Step 6: Phase 1 — boot-through validation (NO disk writes)"
  sed "s#@ROOT_DEV@#$ROOT_DEV#g" "$ETH_SKILL/init-phase1.sh" > "$WORK/init.phase1"
  bash "$ETH_SKILL/build_initramfs.sh" --init "$WORK/init.phase1" --out "$WORK/initrd-validate.cpio.gz" --modules "$MODULES" 2>&1 | grep -vE "Permanently added|^\[build\]" || true
  push_boot "$WORK/initrd-validate.cpio.gz" /boot/initrd-validate
  bash "$ETH_SKILL/set_extlinux_initrd.sh" set /boot/initrd-validate --user "$SSH_USER" --password "$SSH_PASS" >/dev/null
  reboot_and_wait "phase1\]|switch_root|Unpacking initramfs"
  if dssh "cat /proc/1/comm" | grep -qiE "systemd|init"; then
    echo "Phase 1 PASSED."
  else
    die "Phase 1 did not confirm a normal boot — check /tmp/serial.log. Disk untouched; restore: bash $ETH_SKILL/set_extlinux_initrd.sh restore --user $SSH_USER --password $SSH_PASS"
  fi
  [ "$PHASE1_ONLY" = 1 ] && { log "phase1-only requested — stopping."; exit 0; }
fi

# ───────────────────────── Step 7: confirm + Phase 2 (DESTRUCTIVE) ─────────────────────────
log "Step 7: Phase 2 — FLASH (writes are irreversible)"
echo "The following NVMe partitions on $DEVICE_IP will be OVERWRITTEN (in this order):"
i=0
while [ $i -lt ${#M_LABEL[@]} ]; do
  printf "    %-14s -> %s\n" "${M_LABEL[$i]}" "${M_TARGET[$i]}"
  i=$((i+1))
done
echo "  (MBR/GPT and QSPI are NOT touched.)"
if [ "$ASSUME_YES" = 0 ]; then
  printf '\033[1;33mType YES to proceed: \033[0m'
  read -r ans; [ "$ans" = "YES" ] || die "aborted by user (disk untouched)"
fi
push_boot "$WORK/initrd-flasher.cpio.gz" /boot/initrd-flasher
bash "$ETH_SKILL/set_extlinux_initrd.sh" set /boot/initrd-flasher --user "$SSH_USER" --password "$SSH_PASS" >/dev/null
echo "rebooting into flasher — DO NOT cut power..."
dssh "${SUDO}sync; ${SUDO}reboot" || true
sleep 10
rm -f /tmp/serial.log   # drop any stale log so a missing capture isn't mistaken for this flash
serial capture --port linux --timeout 300 >/dev/null 2>&1 || true
# Serial is best-effort observation only. If no serial is attached there is no
# /tmp/serial.log — that must NOT abort the run (pipefail would kill a bare
# `grep missing | tail`). The board flashes and self-reboots regardless; Step 8
# confirms success authoritatively by waiting for SSH + inspecting the booted OS.
if [ -f /tmp/serial.log ]; then
  grep -aiE "flash\]|POINT OF NO RETURN|SELF-HEAL|flashed\.|Rebooting into|writing .* ->" /tmp/serial.log | tail -25 || true
  grep -aiq "partition(s) flashed" /tmp/serial.log || echo "WARNING: did not see completion line in serial log — check /tmp/serial.log"
else
  echo "NOTE: no serial log (no serial attached) — confirming the flash by waiting for SSH to return below."
fi

# ───────────────────────── Step 8: verify result ─────────────────────────
log "Step 8: verify"
echo "waiting for the board to finish flashing and reboot (polls SSH, returns as soon as it answers)..."
wait_ssh 120 || die "device did not come back on SSH after flash (~10–15min budget exhausted) — check serial (/dev/ttyUSB*) to see if it is mid-dd or self-healed"
dssh "echo '== os =='; grep PRETTY /etc/os-release; echo '== root =='; findmnt -no SOURCE,FSTYPE /; echo '== init =='; cat /proc/1/comm; echo '== extlinux initrd =='; grep -i initrd $EXTLINUX || echo '(none — clean)'"

[ "$serial_up" = 1 ] && serial daemon stop >/dev/null 2>&1 || true
log "DONE — board flashed (scope: $SCOPE) and rebooted into the new image."
echo "Note: the new image ships its own SSH host key; clear the old one if needed:"
echo "  ssh-keygen -R $DEVICE_IP"
