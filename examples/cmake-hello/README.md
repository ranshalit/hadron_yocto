# cmake-hello

Minimal C++ CMake app to verify the Hadron cross-compile SDK works.

## Build (host, with SDK installed)

```bash
source /opt/hadron-sdk/environment-setup-armv8a-poky-linux
cmake -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=$OE_CMAKE_TOOLCHAIN_FILE
cmake --build build
```

## Verify + run on device

```bash
file build/hello        # -> ELF 64-bit LSB pie executable, ARM aarch64
scp build/hello ubuntu@192.168.132.100:~
ssh ubuntu@192.168.132.100 ./hello   # -> Hello from Hadron!
```

See the **SDK** section in the repo-root `README.md` for building/installing the SDK.
