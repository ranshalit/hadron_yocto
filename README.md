# Hadron NGX012 Yocto BSP

ConnectTech Hadron NGX012 carrier board with Jetson Orin Nano 4GB (p3767-0003),
built with meta-tegra on Yocto Scarthgap / L4T R36.4.4 (JetPack 6.2.1).

## Build

```bash
kas build kas.yml
kas build kas.yml --target hadron-image-desktop
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
    -y -d /opt/poky/5.0.17
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


# gdb
To configure host GDB to locate your SDKbs unstripped binaries, shared library debug symbols, and source code, you use **three core GDB configurations**: `sysroot`, `file`, and `substitute-path` (or `directory`).

When you source the SDK environment script (`source environment-setup-...`), Yocto sets the `$SDKTARGETSYSROOT` environment variable for you.

---

### Step-by-step GDB Configuration

#### 1. Point GDB to the SDK Sysroot (for Libraries & `.debug` symbols)

By setting the sysroot, GDB automatically knows where to find all target shared libraries (`.so`) and their debug symbols (`usr/lib/debug/` inside the sysroot).

In GDB:

```gdb
(gdb) set sysroot /opt/poky/5.0.17/sysroots/armv8a-poky-linux

```

*(Or, after sourcing the SDK env script, just use the variable: `(gdb) set sysroot $SDKTARGETSYSROOT`)*

The SDK sysroot ships split debug symbols for the OS libraries under
`$SDKTARGETSYSROOT/usr/lib/.debug/` (e.g. `libc.so.6`, `libstdc++.so.6.0.32`) and their
source under `$SDKTARGETSYSROOT/usr/src/debug/` (`glibc`, `gcc-runtime`). With `sysroot`
set, GDB auto-loads these — you can `bt`/`step` straight into libc/libstdc++.

#### 2. Load the Unstripped Application Binary

Always load the unstripped version of your own application binary into host GDB.

* **Option A:** Launch GDB with the file path:
```bash
$GDB /path/to/your/unstripped_app

```


* **Option B:** Load it inside GDB:
```gdb
(gdb) file /path/to/your/unstripped_app

```



#### 3. Map Source Code Paths (for stepping through lines)

GDB reads absolute source file paths embedded in the binary's debug symbols during compilation (e.g., `/usr/src/debug/...` or build directory paths). You need to tell GDB where those source files actually live on your host machine.

* **For System/SDK Libraries (if installed via `src-pkgs`):**
Map the build-time source path to the SDK sysroot source path:
```gdb
(gdb) set substitute-path /usr/src/debug /opt/poky/5.0.17/sysroots/armv8a-poky-linux/usr/src/debug

```


* **For Your Own Application Source Code:**
If the source code is in a local directory on your host:
```gdb
(gdb) directory /path/to/your/local/app/source_code

```



---

### Complete Automation Example (`gdb.setup` script)

Instead of typing these commands every session, create a command script (e.g., `gdb.setup`) in your project root:

```gdb
# gdb.setup

# 1. Set sysroot to SDK sysroot (GDB resolves $SDKTARGETSYSROOT from shell).
#    This alone gives OS-library debug: libc/libstdc++ .debug symbols load automatically.
set sysroot /opt/poky/5.0.17/sysroots/armv8a-poky-linux

# 2. Map system/OS-library source paths (glibc, gcc-runtime, ...)
set substitute-path /usr/src/debug /opt/poky/5.0.17/sysroots/armv8a-poky-linux/usr/src/debug

# 3. Add local source paths
directory ./src

# 4. Connect to gdbserver on the target board
target remote 192.168.1.100:1234

```

Then run it in a single command on your host terminal:

```bash
source /opt/poky/5.0.17/environment-setup-armv8a-poky-linux
$GDB -x gdb.setup /path/to/unstripped_app

```

Once connected, type `c` (continue) in GDB to start debugging.

### Verifying OS library debug works

To confirm GDB can debug into the OS libraries (not just your app), use the `cmake-hello`
example (its `std::cout` calls live in `libstdc++`):

```gdb
(gdb) set sysroot /opt/poky/5.0.17/sysroots/armv8a-poky-linux
(gdb) nosharedlibrary
(gdb) sharedlibrary
(gdb) info sharedlibrary                       # libc/libstdc++ -> "Syms Read: Yes"
(gdb) break std::basic_ostream<char>::operator<<
(gdb) c
(gdb) bt                                        # frames show libstdc++ file:line, not ??
(gdb) step                                      # steps into libstdc++ source lines
```

If `bt` shows named `std::...`/glibc frames **with source file and line numbers**, OS
library debug is working.

# validation
run scripts/hadron-selftest.py


# flash 
using initrd_flash from tegraflash zip

also another alternative:
   L4T=/media/ranshal/jetson/L4T/JetPack_6.2.1_Linux_JETSON_ORIN_NANO_TARGETS/Linux_for ┃
   _Tegra                                                                               ┃
   cd $L4T                                                                              ┃
   sudo ./tools/kernel_flash/l4t_initrd_flash.sh \                                      ┃
     --external-device nvme0n1p1 \                                                      ┃
     -c tools/kernel_flash/flash_l4t_external.xml \                                     ┃
     -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \                               ┃
     --showlogs --network usb0 --no-flash \                                             ┃
     cti/orin-nano/hadron/base internal      

---

## Measuring USB Port Latency / RTT

Utilities to verify a USB port meets a latency budget (e.g. **≤ 5 ms**) live in
`scripts/usb-latency/`. Two complementary methods are used:

| Method | Script | What it measures |
|--------|--------|------------------|
| **usbmon** (kernel URB timing) | `usbmon_latency.py` | Pure host/port service time. The bulk-**OUT** (`Bo`) submit→complete is the cleanest *one-way* USB latency. |
| **Serial loopback RTT** (wall-clock) | `rtt_loopback.py` | End-to-end **round-trip** time through a USB-serial adapter with **TX↔RX shorted**. |

> Why both: usbmon gives a clean one-way OUT number but **cannot** measure receive/round-trip
> (a bulk-IN URB stays *pending* until data arrives, so its time includes device turnaround, not port latency).
> The loopback RTT covers the round-trip that usbmon can't.

### Prerequisites

- A USB-to-serial adapter (FTDI / PL2303 / CDC MCU) plugged into the port under test.
- For the RTT test: **short TX↔RX** on the adapter (DB9: jumper **pin 2 ↔ pin 3**; TTL header: TX pin ↔ RX pin).
- `python3` + `pyserial` (`pip3 install pyserial`).

### Step 0 — remove latency sources first (required, or results lie)

```bash
sudo nvpmodel -m 0 && sudo jetson_clocks                 # max clocks, no scaling jitter
for f in /sys/bus/usb/devices/*/power/control; do echo on | sudo tee "$f"; done   # kill autosuspend
for f in /sys/bus/usb/devices/*/power/usb3_lpm_permit; do echo 0 | sudo tee "$f"; done 2>/dev/null  # kill USB3 LPM
# FTDI adapters only: drop the 16 ms latency timer
echo 1 | sudo tee /sys/bus/usb-serial/devices/ttyUSB0/latency_timer 2>/dev/null
```

> These settings reset on reboot and apply only to devices present at the time.

### Method A — usbmon (one-way, no loopback needed)

```bash
sudo modprobe usbmon
lsusb -t                                                  # find the bus number of your device
sudo timeout 12 cat /sys/kernel/debug/usb/usbmon/<BUS>u > /tmp/cap.txt   # e.g. .../3u
python3 scripts/usb-latency/usbmon_latency.py < /tmp/cap.txt
```

Read the **`Bo:` row** (bulk OUT) — that is the port's one-way send latency. Ignore `Bi:`
(receive URBs wait for data, not the port) and any `Ii:` status endpoint. Needs traffic on the
device while capturing (run Method B in parallel, or `ping` a USB-Ethernet adapter).

### Method B — serial loopback RTT (round-trip)

```bash
python3 scripts/usb-latency/rtt_loopback.py /dev/ttyUSB0 921600 2000
#                                            port         baud   samples
```

Output reports `min / avg / p50 / p99 / p99.9 / max` and a `PASS`/`FAIL` against 5 ms.
**Judge on `max` / `p99.9`, not the average** — a latency spec is a worst-case claim.

Notes:
- Use a **high baud (921600)** so the 1-byte UART wire time is negligible and you measure the USB path, not the serial line.
- In a physical loopback TX and RX share one wire, so a byte is received ~**1 character-time** after send (not two). At 9600 baud that floor is ~1.04 ms — a handy calibration: `min` should track it, proving the measurement is real.
- `mismatch=0` confirms each echoed byte is the one that was sent. `lost` samples (drain races / timeouts) do not inflate latency and are excluded from the stats.
- **Control check:** remove the jumper and rerun — it should report **all `lost`, 0 matched** (proves there is no phantom internal echo).

### Interpreting against a 5 ms spec

| If the spec means… | Compare against | Pass if |
|--------------------|-----------------|---------|
| **One-way** ≤ 5 ms | usbmon `Bo` max, or RTT max / 2 | ≤ 5 ms |
| **Round-trip / response** ≤ 5 ms | `rtt_loopback.py` max | ≤ 5 ms |

`RTT ≈ USB-out + device turnaround + USB-in`, so `RTT/2` is an *upper bound* on one-way latency
(it still carries half the adapter's turnaround). For the true one-way figure, prefer the usbmon `Bo` number.
