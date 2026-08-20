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
echo "=== dmesg: eth0 / link up / nvme / init timestamps ==="
$SSH "sudo dmesg | grep -iE 'eth0|link up|nvme|Run /sbin/init'" || true
