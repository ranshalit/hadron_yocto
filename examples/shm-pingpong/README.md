# shm-pingpong

Two aarch64 apps that talk to each other through **POSIX shared memory** +
**named semaphores**, validated entirely on the host with
`qemu-aarch64-static` (user-mode emulation) — no board, no full-system QEMU.

## Why it works under qemu-user

`qemu-aarch64-static` runs each ARM binary as an ordinary **host** process and
translates its syscalls to the host kernel. So `shm_open()` / `mmap()` /
`sem_open()` create real objects under the host `/dev/shm`, shared by both
emulated processes — exactly like on the real Hadron board.

- `shm_ping` creates the shm region + two semaphores, then sends a message
  each round and waits for the reply.
- `shm_pong` attaches to the same region, waits, reads, increments the shared
  atomic counter, replies.
- Sync is a classic ping/pong with two semaphores (`sem_ping`, `sem_pong`);
  the shared `std::atomic<uint32_t> counter` proves both sides read+write the
  same memory.

## Build (host, with SDK installed)

```bash
source /opt/poky/5.0.17/environment-setup-armv8a-poky-linux
cmake -B build -G Ninja
cmake --build build
```

## Run + validate under QEMU user-mode

Uses the shared, generic launcher `examples/qemu-user-run.sh` (works for any
number of apps in any example — no per-app script needed):

```bash
../qemu-user-run.sh build/shm_ping -- build/shm_pong
```

Expected: alternating `ping`/`pong` lines, the shared counter climbing
`1..10`, and `== OK: all processes exited cleanly ==` with exit code 0.

Override the sysroot if the SDK lives elsewhere:

```bash
HADRON_SYSROOT=/opt/poky/5.0.17/sysroots/armv8a-poky-linux ../qemu-user-run.sh build/shm_ping -- build/shm_pong
```

## Run one side inside an arm64 Docker container

`shm_pong` can run inside an `arm64` container (via `docker run --platform
linux/arm64`, which uses the same `binfmt_misc`/qemu-user emulation) while
`shm_ping` runs bare on the host, and they still talk over shared memory —
as long as the container shares the host's `/dev/shm` and IPC namespace.

One-command version:

```bash
./run-hybrid-docker.sh
```

Or manually, in two terminals:

```bash
# terminal 1: ping on host
qemu-aarch64-static -L /opt/poky/5.0.17/sysroots/armv8a-poky-linux build/shm_ping

# terminal 2: pong in an arm64 container
sudo docker run --rm --platform linux/arm64 --ipc=host \
  -v /dev/shm:/dev/shm -v "$(pwd)/build:/app:ro" \
  ubuntu:22.04 /app/shm_pong
```

- `--platform linux/arm64` — runs the container's binary via `binfmt_misc` +
  qemu-user, same mechanism as calling `qemu-aarch64-static` directly.
- `--ipc=host` — required so the container sees the host's POSIX named
  semaphores (`sem_open`); without it the container gets an isolated IPC
  namespace.
- `-v /dev/shm:/dev/shm` — bind-mounts the host's shm tmpfs so `shm_open()` in
  the container resolves to the same backing memory as the host process.

Check glibc compatibility before doing this: `readelf -V build/<bin> | grep
GLIBC` shows the minimum glibc version needed; make sure the container base
image ships that version or newer (`ubuntu:22.04` ships glibc 2.35, works for
binaries built against this SDK).

## Run on real hardware

Same binaries run natively on the board (they are aarch64 ELFs):

```bash
scp build/shm_ping build/shm_pong ubuntu@192.168.132.100:~
ssh ubuntu@192.168.132.100 './shm_ping & ./shm_pong; wait'
```
