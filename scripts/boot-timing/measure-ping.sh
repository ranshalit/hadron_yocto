#!/usr/bin/env bash
# Power-cycle the board and time power-on -> first ICMP reply.
# Usage: measure-ping.sh [N_RUNS] [TARGET_IP]
# Prints per-run ms and a final "MEDIAN_MS=<n>" line.
set -euo pipefail

N="${1:-5}"
TARGET="${2:-192.168.132.100}"
ZUP="${ZUP_CTL:-/home/ranshal/.copilot/skills/zup-power-supply/scripts/zup_control.py}"
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
