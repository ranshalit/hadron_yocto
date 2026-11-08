#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 || ! "${1:-300}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 [timeout-seconds]" >&2
    exit 2
fi
TIMEOUT=${1:-300}
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LOG_ROOT=${HADRON_QEMU_LOGS:-"$ROOT_DIR/build/qemu-ci"}
mkdir -p "$LOG_ROOT"
RUN_DIR=$(mktemp -d "$LOG_ROOT/run-XXXXXX")
CONSOLE_LOG=$RUN_DIR/console.log
LAUNCHER_LOG=$RUN_DIR/launcher.log

echo "Hadron QEMU boot test (timeout: ${TIMEOUT}s)"
echo "Logs: $RUN_DIR"
HADRON_QEMU_LOGS="$RUN_DIR" bash "$ROOT_DIR/run-qemu.sh" \
    >"$LAUNCHER_LOG" 2>&1 &
QEMU_PID=$!

cleanup() {
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "FAIL: $1" >&2
    for log in "$LAUNCHER_LOG" "$CONSOLE_LOG"; do
        if [[ -f "$log" ]]; then
            echo "--- $log ---" >&2
            tail -n 40 "$log" >&2
        fi
    done
    exit 1
}

DEADLINE=$((SECONDS + TIMEOUT))
while true; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        fail "QEMU exited before reaching a login prompt."
    fi
    if [[ -f "$CONSOLE_LOG" ]]; then
        if grep -aq 'Kernel panic' "$CONSOLE_LOG"; then
            fail "Kernel panic detected."
        fi
        if grep -aEq '^[[:alnum:]_.-]+ login:[[:space:]]*$' "$CONSOLE_LOG"; then
            echo "PASS: hadron-ngx012 reached a login prompt."
            exit 0
        fi
    fi
    if (( SECONDS >= DEADLINE )); then
        fail "Timed out after ${TIMEOUT}s waiting for a login prompt."
    fi
    sleep 0.2
done
