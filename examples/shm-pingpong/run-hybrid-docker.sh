#!/usr/bin/env bash
#
# Run shm_ping bare on the host (qemu-aarch64-static) and shm_pong inside an
# arm64 Docker container, sharing POSIX shm + named semaphores.
#
# Requires: qemu-aarch64-static, docker with arm64 binfmt_misc registered
# (`docker run --rm --platform linux/arm64 ubuntu:22.04 uname -m` should
# print "aarch64"), and build/shm_ping + build/shm_pong already built.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
SYSROOT="${HADRON_SYSROOT:-/opt/poky/5.0.17/sysroots/armv8a-poky-linux}"
QEMU="${QEMU:-qemu-aarch64-static}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"

for b in shm_ping shm_pong; do
    if [[ ! -x "$BUILD/$b" ]]; then
        echo "error: $BUILD/$b not built. Run: cmake -B build -G Ninja && cmake --build build" >&2
        exit 1
    fi
done

rm -f /dev/shm/*hadron_pingpong* /dev/shm/sem.hadron_pingpong* 2>/dev/null || true

echo "== starting ping natively on host (qemu-user) =="
"$QEMU" -L "$SYSROOT" "$BUILD/shm_ping" &
PING_PID=$!

sleep 0.3

echo "== starting pong inside arm64 docker container =="
sudo docker run --rm \
    --platform linux/arm64 \
    --ipc=host \
    -v /dev/shm:/dev/shm \
    -v "$BUILD:/app:ro" \
    "$DOCKER_IMAGE" /app/shm_pong &
PONG_PID=$!

rc=0
wait "$PING_PID" || rc=$?
wait "$PONG_PID" || rc=$?

if [[ $rc -eq 0 ]]; then
    echo "== OK: host process and docker container exchanged messages over shared memory =="
else
    echo "== FAIL: exit code $rc ==" >&2
fi
exit $rc
