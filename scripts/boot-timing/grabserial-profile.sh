#!/usr/bin/env bash
# Full-boot serial attribution via grabserial + PSU power-cycle.
# Power-cycles the board and timestamps the whole MB1 -> UEFI -> kernel ->
# systemd chain on the TCU0 console (Linux console is on TCU0 after the
# console-redirect revert, so one cable captures everything).
#
# Usage: grabserial-profile.sh [SERIAL_DEV] [OUT_FILE] [ENDTIME_S]
# If SERIAL_DEV omitted, auto-picks the /dev/serial/by-id port that is NOT the
# ZUP PSU (Prolific ATEN adapter).
set -euo pipefail

ZUP="${ZUP_CTL:-/home/ranshal/.copilot/skills/zup-power-supply/scripts/zup_control.py}"
OFF_SETTLE="${OFF_SETTLE:-5}"
END="${3:-60}"
OUT="${2:-/tmp/grabserial-boot.txt}"

pick_dev() {
  # Prefer explicit arg
  if [ "${1:-}" != "" ]; then echo "$1"; return; fi
  # Auto: any by-id serial that is not the PSU (Prolific/ATEN)
  for l in /dev/serial/by-id/*; do
    [ -e "$l" ] || continue
    case "$l" in
      *Prolific*|*ATEN*) continue ;;   # that's the PSU
      *) readlink -f "$l"; return ;;
    esac
  done
  echo ""    # none found
}

DEV="$(pick_dev "${1:-}")"
if [ -z "$DEV" ]; then
  echo "ERROR: could not find a board-console serial port (only the PSU is connected?)." >&2
  echo "Connect the Jetson TCU0 console adapter and retry, or pass the device explicitly." >&2
  exit 1
fi
echo "Using board console: $DEV  (PSU stays on its own port)"

# Milestone patterns whose timestamps grabserial reports at end of run (-i).
# Adjust patterns to match actual Hadron firmware/kernel banner lines.
INLINE=(
  -i "MB1"
  -i "MB2"
  -i "\\[L4T"
  -i "Booting Linux"
  -i "Linux version"
  -i "systemd\\[1\\]"
  -i "eth0.*[Ll]ink"
  -i "Reached target"
)

python "$ZUP" off >/dev/null
sleep "$OFF_SETTLE"

# Launch grabserial with base time = launch (-l); power on immediately after.
# -t per-line delta, -T absolute, -e endtime, -o output, -A append log.
( sleep 0.3; python "$ZUP" on >/dev/null ) &
grabserial -d "$DEV" -b 115200 -l -t "${INLINE[@]}" -e "$END" -o "$OUT"
echo
echo "=== saved full timestamped boot log to $OUT ==="
