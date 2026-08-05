# Hadron NGX012 Yocto BSP

ConnectTech Hadron NGX012 carrier board with Jetson Orin Nano 4GB (p3767-0003),
built with meta-tegra on Yocto Scarthgap / L4T R36.4.4 (JetPack 6.2.1).

## Build

```bash
kas build kas.yml
```

See also: https://connecttech.com/resource-center/l4t-board-support-packages/

## SDK (cross-compiling apps on the host)

The image ships a matching cross-toolchain SDK for building host-side C/C++
applications (CMake, autotools, plain Make) against the exact device sysroot.
The SDK bundles its own `cmake`, `ninja`, cross `gcc`/`g++`/`gdb`, and `-dev`
headers for the libraries in the image (boost, opencv, gstreamer, ffmpeg, …),
so it does not depend on the host's own cmake version.

### 1. Build the SDK installer

```bash
kas shell kas.yml -c 'bitbake hadron-image-base -c populate_sdk'
```

Output (a self-extracting installer plus manifests) lands in:

```
build/tmp/deploy/images/../../deploy/sdk/
  poky-glibc-x86_64-hadron-image-base-armv8a-hadron-ngx012-toolchain-5.0.17.sh
```

### 2. Install the SDK

The installer is a single self-extracting file. To use it on another machine,
copy the `.sh` over (e.g. `scp …toolchain-5.0.17.sh host:`), then run it:

```bash
./poky-glibc-x86_64-hadron-image-base-armv8a-hadron-ngx012-toolchain-5.0.17.sh \
    -y -d /opt/hadron-sdk
```

`-y` accepts defaults, `-d` sets the install directory (default `/opt/poky/5.0.17`).

### 3. Build a CMake app

```bash
# Load the cross environment (sets CC, CXX, sysroot, CMAKE_TOOLCHAIN_FILE, PATH)
source /opt/hadron-sdk/environment-setup-armv8a-poky-linux

# The env already exports CMAKE_TOOLCHAIN_FILE, so no -D flag is needed.
# (Do NOT pass -DCMAKE_TOOLCHAIN_FILE=$OE_CMAKE_TOOLCHAIN_FILE — that variable
#  does not exist; passing it empty disables the sysroot and breaks find_library.)
cmake -B build -G Ninja
cmake --build build
```

Minimal example (`CMakeLists.txt` + `main.cpp`):

```cmake
cmake_minimum_required(VERSION 3.10)
project(hello CXX)
add_executable(hello main.cpp)
```

```cpp
#include <iostream>
int main() { std::cout << "Hello from Hadron!" << std::endl; }
```

A ready-to-build copy of this example lives in
[`examples/cmake-hello/`](examples/cmake-hello/).

Verify the output is a Jetson (AArch64) binary, then copy it to the device and run:

```bash
file build/hello        # -> ELF 64-bit LSB pie executable, ARM aarch64
scp build/hello ubuntu@192.168.132.100:~
ssh ubuntu@192.168.132.100 ./hello
```

## Image defaults

| Item | Value |
|---|---|
| Machine | `hadron-ngx012` |
| Image | `hadron-image-base` |
| eth0 IP | `192.168.132.100/24` (static) |
| Login | `ubuntu` / `ubuntu` (has sudo) |

## BMI160 IMU

The image includes full support for the Bosch BMI160 6-axis IMU (accelerometer +
gyroscope) connected to the 40-pin expansion header via I²C.

### Hardware wiring (40-pin header)

| Pin | Signal | BMI160 |
|-----|--------|--------|
| 1   | 3.3 V  | VDD + VDDIO |
| 3   | I²C SDA | SDA |
| 5   | I²C SCL | SCL |
| 9   | GND    | GND + SDO (SDO=VCC → addr 0x69) |

CSB must be pulled HIGH (3.3 V) to enable I²C mode.
SDO pulled to VCC → I²C address **0x69**.

### How it works

- `bmi160.cfg` kernel config fragment builds `bmi160_core.ko` + `bmi160_i2c.ko`
  (`CONFIG_BMI160=m`, `CONFIG_BMI160_I2C=m`) as part of the normal Yocto kernel build.
- `bmi160-config` recipe installs:
  - `/etc/modules-load.d/bmi160.conf` — autoloads `bmi160_i2c` via systemd at boot
  - `/etc/udev/rules.d/99-bmi160.rules` — instantiates the device on the correct
    I²C bus via sysfs (`echo bmi160 0x69 > /sys/bus/i2c/devices/<bus>/new_device`)

No device tree overlay is required.

### Verification (after flash)

```bash
# Discover the I²C bus number for the 40-pin header
i2cdetect -l

# Confirm BMI160 responds at 0x69 (replace 7 with actual bus number)
i2cdetect -r -y 7

# Check IIO device
ls /sys/bus/iio/devices/
cat /sys/bus/iio/devices/iio:device0/name          # → bmi160
cat /sys/bus/iio/devices/iio:device0/in_accel_x_raw
cat /sys/bus/iio/devices/iio:device0/in_anglvel_x_raw
```

## Yocto vs. Ubuntu (lsmod comparison)

The Yocto image shows a different set of modules in `lsmod` compared to the standard 
Ubuntu distribution for the same Jetson hardware. This is expected: while many 
drivers (like `nvgpu`, `nvmap`, and `tegra_drm`) are present as modules in both 
environments, the specific kernel build configuration in Yocto may influence 
which drivers are loaded as modules versus built directly into the kernel image.

If you encounter issues with specific hardware functionality, please check the 
system logs (`dmesg`) to verify the driver status.

