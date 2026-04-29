# Hadron NGX012 Yocto BSP

ConnectTech Hadron NGX012 carrier board with Jetson Orin Nano 4GB (p3767-0003),
built with meta-tegra on Yocto Scarthgap / L4T R36.4.4 (JetPack 6.2.1).

## Build

```bash
kas build kas.yml
```

See also: https://connecttech.com/resource-center/l4t-board-support-packages/

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
