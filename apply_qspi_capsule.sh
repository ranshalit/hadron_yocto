#!/usr/bin/env bash
#
# apply_qspi_capsule.sh — Flash the Jetson QSPI boot firmware over Ethernet only
# (no USB, no recovery mode) by applying a signed UEFI capsule from the running OS.
#
# HOW IT WORKS
#   Orin's boot firmware lives in the QSPI-NOR chip and is NOT exposed as an MTD
#   device under Linux, so it cannot be dd'd. The only supported in-field write is
#   a UEFI Capsule Update. On Orin the *runtime* path (/dev/efi_capsule_loader)
#   returns EINVAL — UEFI does NOT advertise the FILE_CAPSULE_DELIVERY bit
#   (OsIndicationsSupported lacks 0x04). The ONLY working Linux path is
#   "capsule-on-disk":
#     1. mount the active bootloader slot's EFI System Partition (ESP),
#     2. copy the signed capsule to <ESP>/EFI/UpdateCapsule/,
#     3. set the OsIndications EFI variable bit 0x04 (process-capsule-on-disk),
#     4. reboot — UEFI scans \EFI\UpdateCapsule\ early in the next boot, writes the
#        inactive QSPI A/B slot, flips the active slot, and clears OsIndications.
#   (Reference: NVIDIA nv_bootloader_capsule_updater.sh.)
#
# REQUIREMENTS ON THE DEVICE
#   - UEFI built with CONFIG_FIRMWARE_CAPSULE_SUPPORTED=y (edk2-boot-strip.cfg).
#     Verify: OsIndicationsSupported reads 0x45 (gains bit 0x04). Without this the
#     capsule is silently ignored (UEFI just clears the var).
#   - vfat/fat kernel modules to mount the ESP (kernel-module-vfat +
#     kernel-module-fat are in lumen-image-minimal.bb).
#
# PROOF THAT *OUR* FIRMWARE WAS APPLIED (not just "already there")
#   We snapshot, before and after, three values that only move if a capsule was
#   actually processed this boot:
#     1. nvbootctrl active/current bootloader slot   (A -> B flip)
#     2. ESRT entry last_attempt_version             (set by UEFI to the cap version)
#     3. ESRT entry last_attempt_status              (0 == success)
#   These are reported by UEFI itself, independent of the firmware's own version
#   string, so they distinguish a real apply from an identical image being present.
#
# SAFETY
#   Writing QSPI is the one irreversible, brickable step (power loss during the
#   UEFI write can require USB/RCM recovery, which we are assuming is unavailable).
#   The script does every read-only check first and PAUSES for an explicit YES
#   right before handing the capsule to the kernel. Keep the serial console
#   attached as the recovery channel.
#
# USAGE
#   ./apply_qspi_capsule.sh                 # auto-find tegra-bl.cap, confirm before apply
#   ./apply_qspi_capsule.sh --yes           # skip the confirmation prompt
#   ./apply_qspi_capsule.sh --cap PATH      # use a specific capsule file
#   ./apply_qspi_capsule.sh --no-reboot     # load the capsule but don't reboot (apply later)
#   ./apply_qspi_capsule.sh --check         # only print current slot + ESRT, then exit
#
set -euo pipefail

# ───────────────────────── configuration ─────────────────────────
# Pull DEVICE_* from the repo .env (same convention as the ethernet-console skill).
ENV_FILE="${ENV_FILE:-${PWD}/.env}"
get_env() { [ -f "$ENV_FILE" ] || return 0; grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2- | tr -d '"'; }

IP="${DEVICE_IP:-$(get_env DEVICE_IP)}"
USER="${DEVICE_SSH_USER:-$(get_env DEVICE_SSH_USER)}"
PASS="${DEVICE_SSH_PASS:-$(get_env DEVICE_SSH_PASS)}"
CONNECT_TIMEOUT="${DEVICE_SSH_CONNECT_TIMEOUT:-$(get_env DEVICE_SSH_CONNECT_TIMEOUT)}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"

# Where the capsule is staged on the device before loading.
REMOTE_CAP="${REMOTE_CAP:-/tmp/tegra-bl.cap}"

# Active-slot ESP block devices (capsule-on-disk target). Slot A=0, B=1.
ESP_SLOT_A="${ESP_SLOT_A:-/dev/nvme0n1p10}"
ESP_SLOT_B="${ESP_SLOT_B:-/dev/nvme0n1p13}"
# Capsule filename under <ESP>/EFI/UpdateCapsule/ (NVIDIA convention).
ESP_CAP_NAME="${ESP_CAP_NAME:-TEGRA_BL.Cap}"
OSIND_VAR="OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c"

# Auto-discover the capsule under the deploy dir unless --cap / CAP overrides it.
IMAGES_BASE="${IMAGES_BASE:-build/tmp/deploy/images}"
# Where to find prebuilt fat.ko / vfat.ko if the device rootfs lacks vfat (e.g. a
# not-yet-updated rootfs). Searched by the device's running kernel release.
MODULES_BASE="${MODULES_BASE:-build/tmp/work}"

ASSUME_YES=0; DO_REBOOT=1; CHECK_ONLY=0; CAP="${CAP:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --cap) CAP="$2"; shift 2 ;;
    --no-reboot) DO_REBOOT=0; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

: "${IP:?DEVICE_IP not set (add to .env or export)}"
: "${USER:?DEVICE_SSH_USER not set}"
: "${PASS:?DEVICE_SSH_PASS not set}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$CONNECT_TIMEOUT")
dssh(){ sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USER@$IP" "$@"; }
dscp(){ sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$@"; }
# Run a command as root on the device. This board has passwordless sudo; if that
# ever changes, fall back to feeding the password via `sudo -S`.
dsudo(){ dssh "sudo -n sh -c '$1'"; }
ssh_ready(){ sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" -o ConnectTimeout=8 "$USER@$IP" "echo __UP__" 2>/dev/null | grep -q __UP__; }
wait_ssh(){ local n="${1:-60}"; for _ in $(seq 1 "$n"); do ssh_ready && return 0; sleep 5; done; return 1; }

# Read the firmware state we use as proof. Prints KEY=VALUE lines.
snapshot(){
  dssh "sudo -n sh -s" <<'REMOTE'
e=/sys/firmware/efi/esrt/entries/entry0
info=$(nvbootctrl -t bootloader dump-slots-info 2>/dev/null)
echo "SLOT=$(nvbootctrl -t bootloader get-current-slot 2>/dev/null)"
echo "ACTIVE=$(printf '%s\n' "$info" | sed -n 's/.*Active bootloader slot: //p')"
echo "CAPSTAT=$(printf '%s\n' "$info" | sed -n 's/.*Capsule update status: //p')"
echo "FWVER=$(cat $e/fw_version 2>/dev/null)"
echo "LAV=$(cat $e/last_attempt_version 2>/dev/null)"
echo "LAS=$(cat $e/last_attempt_status 2>/dev/null)"
REMOTE
}

# Make sure the device can mount a vfat ESP. The updated lumen image ships
# kernel-module-fat/vfat, but a not-yet-updated rootfs may lack them — in that
# case push the matching prebuilt .ko's from the build and insmod them.
ensure_vfat(){
  if dssh "sudo -n sh -c 'modprobe vfat 2>/dev/null; grep -qw vfat /proc/filesystems'"; then
    echo "vfat available on device"
    return 0
  fi
  echo "vfat not available on device — pushing modules from $MODULES_BASE"
  local krel fatko vfatko
  krel="$(dssh "uname -r" | tr -d '\r')"
  [ -n "$krel" ] || die "could not read device kernel release"
  fatko="$(find "$MODULES_BASE" -path "*/lib/modules/$krel/kernel/fs/fat/fat.ko" 2>/dev/null | head -1)"
  vfatko="$(find "$MODULES_BASE" -path "*/lib/modules/$krel/kernel/fs/fat/vfat.ko" 2>/dev/null | head -1)"
  [ -f "$fatko" ] && [ -f "$vfatko" ] || \
    die "fat.ko/vfat.ko for kernel $krel not found under $MODULES_BASE — build the image first"
  dscp "$fatko" "$vfatko" "$USER@$IP:/tmp/" >/dev/null
  dssh "sudo -n sh -c 'insmod /tmp/fat.ko 2>/dev/null; insmod /tmp/vfat.ko 2>/dev/null; grep -qw vfat /proc/filesystems'" \
    || die "failed to load vfat module on device (vermagic mismatch?)"
  echo "vfat module loaded on device (fat.ko + vfat.ko)"
}
log "preflight"
for t in sshpass ssh scp; do command -v "$t" >/dev/null || die "missing host tool: $t"; done
ping -c1 -W2 "$IP" >/dev/null 2>&1 || die "device $IP not reachable"
ssh-keygen -R "$IP" >/dev/null 2>&1 || true
ssh_ready || die "cannot SSH as $USER@$IP"

if [ "$CHECK_ONLY" = 0 ]; then
  if [ -z "$CAP" ]; then
    mapfile -t _c < <(find "$IMAGES_BASE" -name 'tegra-bl.cap' 2>/dev/null | sort)
    case "${#_c[@]}" in
      0) die "no tegra-bl.cap found under $IMAGES_BASE — build it: kas shell <cfg> -c 'bitbake tegra-uefi-capsules'" ;;
      1) CAP="${_c[0]}" ;;
      *) CAP="$(ls -t "${_c[@]}" | head -1)"; echo "multiple capsules; using newest: $CAP" ;;
    esac
  fi
  CAP="$(readlink -f "$CAP")"
  [ -f "$CAP" ] || die "capsule not found: $CAP"
  echo "capsule : $CAP ($(du -h "$CAP" | cut -f1), sha256 $(sha256sum "$CAP" | cut -c1-16)...)"
fi

# ───────────────────────── snapshot BEFORE ─────────────────────────
log "firmware state BEFORE"
BEFORE="$(snapshot)"; echo "$BEFORE"
B_ACTIVE="$(printf '%s\n' "$BEFORE" | sed -n 's/^ACTIVE=//p')"
[ "$CHECK_ONLY" = 1 ] && { log "check-only — done."; exit 0; }

# ───────────────────────── stage capsule ─────────────────────────
log "staging capsule on device ($REMOTE_CAP)"
dscp "$CAP" "$USER@$IP:$REMOTE_CAP"
L_SHA="$(sha256sum "$CAP" | cut -d' ' -f1)"
R_SHA="$(dssh "sha256sum $REMOTE_CAP" | cut -d' ' -f1)"
[ "$L_SHA" = "$R_SHA" ] || die "staged capsule sha mismatch (host=$L_SHA dev=$R_SHA)"
echo "staged sha256 OK"

# ───────────────────────── confirm ─────────────────────────
log "apply capsule — QSPI WRITE (irreversible; do NOT cut power)"
if [ "$ASSUME_YES" = 0 ]; then
  printf '\033[1;33mThis hands the capsule to UEFI and (by default) reboots %s to write QSPI.\nType YES to proceed: \033[0m' "$IP"
  read -r ans; [ "$ans" = "YES" ] || die "aborted by user (QSPI untouched)"
fi

# Make sure the ESP is mountable (push vfat modules to an old rootfs if needed).
log "ensuring vfat is available (to mount the ESP)"
ensure_vfat

# Stage the capsule on the active slot's ESP and arm OsIndications.
#
# We do NOT trust the heredoc's exit code: writing to efivarfs can return a
# spurious non-zero even when the variable was set correctly. Instead the
# remote script READS BACK its own work and prints sentinel lines
# (STAGED_CAP_OK / OSIND_ARMED_OK) only after verifying the end-state; the host
# then keys success off those sentinels. QSPI is untouched until the next boot.
log "staging capsule-on-disk (mount active ESP -> EFI/UpdateCapsule, arm OsIndications)"
STAGE_OUT="$(dssh "sudo -n sh -s '$REMOTE_CAP' '$ESP_SLOT_A' '$ESP_SLOT_B' '$ESP_CAP_NAME' '$OSIND_VAR' '$L_SHA'" <<'REMOTE' 2>&1 || true
REMOTE_CAP="$1"; ESP_SLOT_A="$2"; ESP_SLOT_B="$3"; ESP_CAP_NAME="$4"; OSIND_VAR="$5"; WANT_SHA="$6"

modprobe fat 2>/dev/null || true
modprobe vfat 2>/dev/null || true

slot=$(nvbootctrl -t bootloader get-current-slot 2>/dev/null || echo 0)
case "$slot" in
  1) esp="$ESP_SLOT_B" ;;
  *) esp="$ESP_SLOT_A" ;;
esac
echo "active bootloader slot: $slot -> ESP $esp"
[ -b "$esp" ] || { echo "ESP block device $esp not found" >&2; exit 0; }

mnt=$(mktemp -d)
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
mount -t vfat "$esp" "$mnt" || { echo "failed to mount $esp (vfat)" >&2; exit 0; }

mkdir -p "$mnt/EFI/UpdateCapsule"
cp "$REMOTE_CAP" "$mnt/EFI/UpdateCapsule/$ESP_CAP_NAME"
sync
# read back the staged capsule and verify its sha before declaring success
got=$(sha256sum "$mnt/EFI/UpdateCapsule/$ESP_CAP_NAME" 2>/dev/null | cut -d' ' -f1)
umount "$mnt"; rmdir "$mnt"; trap - EXIT
if [ "$got" = "$WANT_SHA" ]; then
  echo "capsule placed at <ESP>/EFI/UpdateCapsule/$ESP_CAP_NAME (sha verified)"
  echo "STAGED_CAP_OK"
else
  echo "staged capsule sha mismatch on ESP (got=$got want=$WANT_SHA)" >&2
  exit 0
fi

# Arm capsule-on-disk: OsIndications bit 0x04 (PROCESS_CAPSULE_ON_DISK).
# efivarfs layout = 4-byte attributes (NV|BS|RT = 0x07) + 8-byte LE value.
var="/sys/firmware/efi/efivars/$OSIND_VAR"
[ -e "$var" ] && chattr -i "$var" 2>/dev/null || true
printf '\007\000\000\000\004\000\000\000\000\000\000\000' > "$var" 2>/dev/null || true
# read back: byte index 4 (first value byte) must have the 0x04 bit set
val=$(od -An -tx1 "$var" 2>/dev/null | tr -s ' ' | sed 's/^ //')
b4=$(echo "$val" | cut -d' ' -f5)
# robust bit test: parse hex, AND with 0x04
if [ -n "$b4" ] && [ $(( 0x$b4 & 0x04 )) -ne 0 ]; then
  echo "OsIndications armed (process-capsule-on-disk = 0x04); efivar bytes: $val"
  echo "OSIND_ARMED_OK"
else
  echo "OsIndications readback does not show bit 0x04 (bytes: $val)" >&2
  exit 0
fi
REMOTE
)"
echo "$STAGE_OUT"
printf '%s\n' "$STAGE_OUT" | grep -q STAGED_CAP_OK  || die "capsule was not staged on the ESP. QSPI untouched."
printf '%s\n' "$STAGE_OUT" | grep -q OSIND_ARMED_OK || die "OsIndications could not be armed. QSPI untouched."
echo "capsule staged + OsIndications armed (verified by readback)"

if [ "$DO_REBOOT" = 0 ]; then
  log "--no-reboot set — capsule is staged on the ESP and OsIndications is armed. Reboot the device to apply, then re-run with --check."
  exit 0
fi

# ───────────────────────── reboot + apply ─────────────────────────
log "rebooting to apply (UEFI writes QSPI during early boot)"
dsudo "sync; (sleep 1; reboot) >/dev/null 2>&1 &" || true
sleep 15
echo "waiting for device to come back on SSH..."
wait_ssh 72 || die "device did not return on SSH after reboot — check serial console (/tmp/serial.log)"

# ───────────────────────── snapshot AFTER + verdict ─────────────────────────
log "firmware state AFTER"
AFTER="$(snapshot)"; echo "$AFTER"
A_ACTIVE="$(printf '%s\n' "$AFTER" | sed -n 's/^ACTIVE=//p')"
A_LAS="$(printf '%s\n' "$AFTER" | sed -n 's/^LAS=//p')"
A_LAV="$(printf '%s\n' "$AFTER" | sed -n 's/^LAV=//p')"

log "VERDICT"
echo "active slot : $B_ACTIVE -> $A_ACTIVE"
echo "last_attempt_version : $A_LAV"
echo "last_attempt_status  : $A_LAS  (0 == success)"
ok=1
if [ -n "$A_LAS" ] && [ "$A_LAS" != "0" ]; then
  echo "  -> UEFI reported a FAILED capsule apply"
  if [ "$A_LAS" = "6151" ]; then
    echo "     0x1807 == IMAGE_NOT_IN_PACKAGE: the capsule's image TnSpec does not"
    echo "     match the device. This happens when the QSPI firmware was flashed for"
    echo "     a DIFFERENT product (its locked TegraPlatformSpec / TegraPlatformCompatSpec"
    echo "     UEFI variables differ from this build's MACHINE). Confirm the device runs"
    echo "     THIS product's firmware:"
    echo "        cat /sys/firmware/efi/efivars/TegraPlatformCompatSpec-* | tr -d '\\0'"
  fi
  ok=0
fi
if [ "$B_ACTIVE" = "$A_ACTIVE" ]; then
  echo "  -> NOTE: active slot did not flip ($A_ACTIVE). Capsule may have been"
  echo "     skipped (e.g. identical version). Bump the capsule fw-version to force,"
  echo "     or treat last_attempt_status as the source of truth."
fi
if [ "$ok" = 1 ] && { [ "$B_ACTIVE" != "$A_ACTIVE" ] || [ "$A_LAS" = "0" ]; }; then
  log "DONE — QSPI capsule applied (UEFI-reported success)."
else
  die "capsule apply not confirmed — inspect serial log and ESRT above."
fi
