# cmake-hello

Minimal C++ CMake app to verify the Hadron cross-compile SDK works.

## Build (host, with SDK installed)

```bash
source /opt/hadron-sdk/environment-setup-armv8a-poky-linux
cmake -B build -G Ninja
cmake --build build
```

## Verify + run on device

```bash
file build/hello        # -> ELF 64-bit LSB pie executable, ARM aarch64
scp build/hello ubuntu@192.168.132.100:~
ssh ubuntu@192.168.132.100 ./hello   # -> Hello from Hadron!
```

See the **SDK** section in the repo-root `README.md` for building/installing the SDK.

## Remote debug from VS Code

The `.vscode/` folder in this example wires up remote GDB debugging against
`gdbserver` on the board — including OS-library (libc/libstdc++) debug.

**Requirements (host):**

- VS Code **C/C++** extension (`ms-vscode.cpptools`)
- `sshpass` (`sudo apt install sshpass`) — used by the deploy task to scp + start gdbserver
- SDK installed at `/opt/poky/5.0.17` (ships its own `aarch64-poky-linux-gdb`)

**Configure the target** in `.vscode/settings.json`:

```json
{
  "hadron.sdkRoot": "/opt/poky/5.0.17",
  "hadron.deviceIp": "192.168.132.100",
  "hadron.deviceUser": "ubuntu",
  "hadron.devicePassword": "ubuntu",
  "hadron.appBinary": "hello"
}
```

`hadron.sdkRoot` is the SDK install dir (the `-d` path from installing the toolchain) and
`hadron.appBinary` is your CMake target's output name — change these two and the same
`.vscode/` works for any app / SDK location.

**Debug:** open this folder in VS Code and press **F5**
(*Remote debug hello (gdbserver on Hadron)*). It will:

1. Build with the SDK (`build (SDK)` task, `-DCMAKE_BUILD_TYPE=Debug`).
2. `scp` the unstripped binary and start `gdbserver :1234 ./hello` on the device
   (`deploy-and-start-gdbserver` task).
3. Launch the SDK's `aarch64-poky-linux-gdb`, connect to the target, and set `sysroot`
   + `substitute-path` so breakpoints, backtraces, and *stepping into libc/libstdc++*
   all resolve to source.

Set a breakpoint in `main.cpp`, or in library code (e.g. break on
`std::basic_ostream<char>::operator<<`) and step in — the call stack shows named
libstdc++/glibc frames with source, proving OS-library debug works.

> Prefer SSH keys? Add your key to the board (`ssh-copy-id ubuntu@<ip>`) and drop the
> `sshpass -p '…'` prefixes from the `deploy-and-start-gdbserver` task in
> `.vscode/tasks.json`.
