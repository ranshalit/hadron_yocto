# Examples — running AArch64 apps on this x86 host

This covers every way to **run** an already-built AArch64 (Jetson/Hadron target)
binary or Docker image directly on this x86 development machine, without the
real board. All of them ultimately rely on the same underlying mechanism:
**`qemu-user`** (process-level CPU emulation), registered with the kernel via
`binfmt_misc`. None of this is full-system emulation (`qemu-system-aarch64`,
i.e. `run-qemu.sh` at the repo root) — no separate guest kernel is booted; the
host kernel's own syscalls are used directly.

Confirm binfmt_misc is registered on this host:

```bash
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
# enabled
# interpreter /usr/libexec/qemu-binfmt/aarch64-binfmt-P   (symlink to qemu-aarch64-static)
```

## Option 1 — `qemu-aarch64-static` directly

The most explicit way. You choose the sysroot with `-L`:

```bash
qemu-aarch64-static -L /opt/poky/5.0.17/sysroots/armv8a-poky-linux ./build/hello
```

`-L <sysroot>` tells qemu-user where to find the AArch64 dynamic linker
(`/lib/ld-linux-aarch64.so.1`) and shared libs (`libc.so.6`,
`libstdc++.so.6`, ...) that the binary needs — the host's real root
filesystem has none of these (it's x86_64), so without `-L` the binary can't
resolve them.

## Option 2 — run the binary directly (binfmt_misc, no explicit prefix)

Because `binfmt_misc` is registered, you can just execute the ELF like a
native program — the kernel transparently reroutes it through
`aarch64-binfmt-P` (== `qemu-aarch64-static`) for you:

```bash
export QEMU_LD_PREFIX=/opt/poky/5.0.17/sysroots/armv8a-poky-linux
./build/hello
```

`QEMU_LD_PREFIX` is the env-var equivalent of `-L`, needed because binfmt
invocation can't pass a `-L` flag directly. Only required for
*dynamically-linked* binaries; a statically-linked AArch64 binary would run
with no sysroot config at all.

## Option 3 — the generic `qemu-user-run.sh` script

Reusable across every example — no per-app script needed. Launches any
number of AArch64 binaries in parallel (bare qemu-user, and/or Docker
containers — see below), waits for all, reports pass/fail.

```bash
cd examples
./qemu-user-run.sh <binary1> [args...] -- <binary2> [args...] -- ...
```

- Any number of `--` separators is fine — **N apps need N-1 `--`**.
- Env overrides: `HADRON_SYSROOT` (default
  `/opt/poky/5.0.17/sysroots/armv8a-poky-linux`), `QEMU` (default
  `qemu-aarch64-static`), `DOCKER` (default `sudo docker`).

Single app:
```bash
./qemu-user-run.sh cmake-hello/build/hello
```

Two apps talking to each other (e.g. over shared memory, see
[`shm-pingpong/`](shm-pingpong/)):
```bash
./qemu-user-run.sh shm-pingpong/build/shm_ping -- shm-pingpong/build/shm_pong
```

Three (or more) apps in one call, mixed freely:
```bash
./qemu-user-run.sh cmake-hello/build/hello -- shm-pingpong/build/shm_ping -- shm-pingpong/build/shm_pong
```

## Option 4 — Docker container running an AArch64 image

`docker run --platform linux/arm64 <image>` also goes through the exact same
`aarch64-binfmt-P` (qemu-user) path under the hood — Docker only adds
filesystem/network isolation on top, it does not change the emulation layer.
Verified: a container's process shows up on the host `ps` output as
`/usr/libexec/qemu-binfmt/aarch64-binfmt-P <container's binary>`.

Manual form:
```bash
sudo docker run --rm --platform linux/arm64 --ipc=host \
  -v /dev/shm:/dev/shm -v /abs/path/to/build:/app:ro \
  ubuntu:22.04 /app/shm_pong
```

- `--platform linux/arm64` — pulls/uses the **arm64 variant** of the image
  (most Docker Hub images are multi-arch manifests; without this flag Docker
  defaults to the host's native x86_64 variant, no emulation happens).
- `--ipc=host` — only needed if the app shares POSIX named semaphores /
  shared memory with a process outside the container; shares the host IPC
  namespace so `sem_open()` objects are visible in both places.
- `-v /dev/shm:/dev/shm` — same reasoning: bind-mounts the host's shm tmpfs
  so `shm_open()`/`mmap()` resolve to the same backing memory as an
  outside-the-container process.

Via `qemu-user-run.sh`, use the `docker` group syntax instead of a plain
binary path:

```bash
docker <image> <host-dir-to-mount-as-/app> <path/in/container> [args...]
```

Example — `shm_ping` bare on host, `shm_pong` inside a docker container, one
command:
```bash
./qemu-user-run.sh shm-pingpong/build/shm_ping -- docker ubuntu:22.04 shm-pingpong/build /app/shm_pong
```

The script resolves the host-dir to an absolute path automatically (Docker's
`-v` requires absolute paths).

### If your Docker image is only a `.tar` file (no registry)

```bash
sudo docker load -i my-app.tar
# check it's really arm64 (docker save on an x86 host, without --platform,
# saves the x86_64 variant by default):
sudo docker image inspect <name>:<tag> --format '{{.Architecture}}'   # must print arm64
```
Then run it exactly as in Option 4 above, using `<name>:<tag>` as `<image>`.
`docker load` itself is pure data unpacking — it always succeeds regardless
of architecture; it's only `docker run` that needs the emulation path above
to actually execute the binaries inside.

## Summary table

| Method | Command | Notes |
|---|---|---|
| Explicit qemu-user | `qemu-aarch64-static -L $SYSROOT ./bin` | Most direct, most control |
| Implicit (binfmt) | `QEMU_LD_PREFIX=$SYSROOT ./bin` | No visible qemu prefix |
| Generic script, bare | `./qemu-user-run.sh bin1 -- bin2` | Reusable, multi-app, parallel |
| Generic script, docker | `./qemu-user-run.sh bin1 -- docker <img> <dir> <path>` | Mix host + container apps |
| Docker manual | `docker run --platform linux/arm64 ...` | Adds fs/network isolation |

All rows: same `qemu-user` CPU emulation underneath. None of this boots a
separate kernel — for that (full-system emulation), see `run-qemu.sh` at the
repo root, which boots the whole `hadron-image-base` image under
`qemu-system-aarch64`.
