#!/usr/bin/env bash
#
# Generic launcher: run one or more aarch64 binaries under qemu-aarch64-static
# (user-mode emulation), in parallel, and wait for all of them.
#
# Reusable across examples — no per-app script needed. Just pass the built
# binaries (with any args) as separate quoted arguments, separated by "--":
#
#   ./qemu-user-run.sh path/to/bin1 -- path/to/bin2 --flag value
#
# Any number of "--" is fine (N apps need N-1 "--"), and any group can
# instead be a Docker app by starting it with the literal word "docker":
#
#   docker <image> <host-dir-to-mount-as-/app> <path/in/container> [args...]
#
#   ./qemu-user-run.sh build/shm_ping -- docker ubuntu:22.04 build /app/shm_pong
#
# This runs the container with the flags needed for it to share host POSIX
# shm/semaphores with the qemu-user apps:
#   --platform linux/arm64  -> runs the arm64 image via binfmt_misc (same
#                              qemu-user tech as bare qemu-aarch64-static).
#   --ipc=host               -> shares the host IPC namespace so POSIX named
#                              semaphores (sem_open) are visible in-container.
#   -v /dev/shm:/dev/shm     -> bind-mounts the host's shm tmpfs so
#                              shm_open()/mmap() see the same backing files.
#   -v <host-dir>:/app:ro    -> makes the built binaries available in-container.
#
# Env overrides:
#   HADRON_SYSROOT  - SDK sysroot for the dynamic loader/libs (default below)
#   QEMU            - qemu-user binary (default: qemu-aarch64-static)
#   DOCKER          - docker invocation (default: sudo docker)
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <binary1 [args...]> [-- <binary2 [args...]>] ..." >&2
    echo "example: $0 build/shm_ping -- build/shm_pong" >&2
    echo "example: $0 build/shm_ping -- docker ubuntu:22.04 build /app/shm_pong" >&2
    exit 1
fi

SYSROOT="${HADRON_SYSROOT:-/opt/poky/5.0.17/sysroots/armv8a-poky-linux}"
QEMU="${QEMU:-qemu-aarch64-static}"
DOCKER="${DOCKER:-sudo docker}"

if ! command -v "$QEMU" >/dev/null 2>&1; then
    echo "error: $QEMU not found on PATH" >&2
    exit 1
fi
if [[ ! -d "$SYSROOT" ]]; then
    echo "error: sysroot not found: $SYSROOT (set HADRON_SYSROOT)" >&2
    exit 1
fi

# Split the arg list on literal "--" into one group of args per app.
groups=()
current=()
for a in "$@"; do
    if [[ "$a" == "--" ]]; then
        groups+=("$(printf '%q ' "${current[@]}")")
        current=()
    else
        current+=("$a")
    fi
done
groups+=("$(printf '%q ' "${current[@]}")")

pids=()
for group in "${groups[@]}"; do
    eval "set -- $group"
    if [[ "${1:-}" == "docker" ]]; then
        # docker <image> <host-dir> <container-path> [args...]
        image="$2"; hostdir="$(cd "$3" && pwd)"; shift 3
        echo "== launching (docker): $DOCKER run --rm --platform linux/arm64 --ipc=host -v /dev/shm:/dev/shm -v $hostdir:/app:ro $image $* =="
        $DOCKER run --rm --platform linux/arm64 --ipc=host \
            -v /dev/shm:/dev/shm -v "$hostdir:/app:ro" \
            "$image" "$@" &
    else
        echo "== launching: $QEMU -L $SYSROOT $* =="
        "$QEMU" -L "$SYSROOT" "$@" &
    fi
    pids+=($!)
done

rc=0
for pid in "${pids[@]}"; do
    wait "$pid" || rc=$?
done

if [[ $rc -eq 0 ]]; then
    echo "== OK: all processes exited cleanly =="
else
    echo "== FAIL: at least one process exited non-zero (last rc=$rc) ==" >&2
fi
exit $rc
