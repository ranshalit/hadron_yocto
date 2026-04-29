# Copilot Instructions — Hadron Yocto BSP

## Project Overview

This is a Yocto BSP project targeting the ConnectTech **Hadron NGX012** carrier board with a
**Jetson Orin Nano 4GB** (p3767-0003) SoM. It uses CTI's L4T 36.4.4 (JetPack 6.2.1) BSP.

- **Yocto machine**: `hadron-ngx012`
- **Build command**: `kas build kas.yml`
- **Build image**: `hadron-image-base`
- **L4T version**: R36.4.4 (CTI-L4T-ORIN-NX-NANO-36.4.4-V005)

---

## Flashing the Device

### Overview

Use the CTI L4T BSP's `l4t_initrd_flash.sh --network usb0` mechanism, injecting all
partition images from the Yocto `tegraflash.tar.gz`. This uses USB Ethernet + SSH to write
partitions from inside a running recovery Linux — it reliably detects NVMe.

> ⚠️ **Do NOT use Yocto's built-in `initrd-flash`** (USB mass-storage). It fails on this
> board because `/dev/nvme0n1` never appears within the 15-second device-side timeout in
> meta-tegra's recovery initrd.

### Prerequisites

```bash
sudo apt install sshpass nfs-kernel-server abootimg zstd
```

### Key Paths

```
YOCTO=/media/ranshal/jetson/hadron_yocto/build/tmp/deploy/images/hadron-ngx012
L4T=/media/ranshal/jetson/L4T/JetPack_6.2.1_Linux_JETSON_ORIN_NANO_TARGETS/Linux_for_Tegra
TARBALL=$YOCTO/hadron-image-base-hadron-ngx012.rootfs.tegraflash.tar.gz
IMAGES=$L4T/tools/kernel_flash/images/external
```

### Step 1 — Put device in recovery mode

Connect the board via USB (recovery port). Hold the recovery button while powering on (or
pressing reset). Verify:

```bash
lsusb | grep -i nvidia   # must show: 0955:7523 NVIDIA Corp. APX
```

### Step 2 — Generate signed flash package (board must be in recovery)

```bash
cd $L4T
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
  --external-device nvme0n1p1 \
  -c tools/kernel_flash/flash_l4t_external.xml \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
  --showlogs --network usb0 \
  --no-flash \
  cti/orin-nano/hadron/base internal
```

This reads the board ECID over USB, signs all T234 bootloader images, and generates
`tools/kernel_flash/images/external/` with default L4T partition images. The board is
not flashed yet — it stays in recovery mode.

### Step 3 — Extract Yocto tegraflash tarball

```bash
mkdir -p /tmp/yocto-flash
tar xzf $TARBALL -C /tmp/yocto-flash
```

### Step 4 — Inject Yocto images into flash workspace

```bash
# Kernel + CTI DTB (boot.img)
sudo cp /tmp/yocto-flash/boot.img $IMAGES/boot.img

# EFI System Partition
sudo cp /tmp/yocto-flash/esp.img $IMAGES/esp.img

# Rootfs: compress the Yocto ext4 as zstd (device-side writes it directly via dd)
sudo zstd -T0 /tmp/yocto-flash/hadron-image-base.ext4 -o $IMAGES/system.img.zst
sudo sha1sum $IMAGES/system.img.zst | awk '{print $1}' | sudo tee $IMAGES/system.img.zst.sha1sum
sudo rm -f $IMAGES/system.img $IMAGES/system.img.sha1sum

# Update flash.cfg to reference the .zst file
sudo sed -i 's/APP_ext=system\.img$/APP_ext=system.img.zst/' $IMAGES/flash.cfg

# Update flash.idx: fix boot.img file_size and sha1 for A_kernel and B_kernel entries
BOOT_SIZE=$(stat -c%s $IMAGES/boot.img)
BOOT_SHA1=$(sha1sum $IMAGES/boot.img | awk '{print $1}')
ESP_SHA1=$(sha1sum $IMAGES/esp.img | awk '{print $1}')

# Update kernel entries in flash.idx (adjust sed patterns if flash.idx format changes)
sudo python3 - <<'EOF'
import re, subprocess, pathlib

idx = pathlib.Path("tools/kernel_flash/images/external/flash.idx")
boot_size = int(subprocess.check_output(["stat","-c%s","tools/kernel_flash/images/external/boot.img"]).strip())
boot_sha1 = subprocess.check_output(["sha1sum","tools/kernel_flash/images/external/boot.img"]).split()[0].decode()
esp_sha1  = subprocess.check_output(["sha1sum","tools/kernel_flash/images/external/esp.img"]).split()[0].decode()

text = idx.read_text()
def fix_entry(m):
    parts = m.group(0).split(", ")
    if "boot.img" in parts[3]:
        parts[4] = str(boot_size)
        parts[6] = boot_sha1
    elif "esp.img" in parts[3]:
        parts[6] = esp_sha1
    return ", ".join(parts)

text = re.sub(r'[^\n]+boot\.img[^\n]+', fix_entry, text)
text = re.sub(r'[^\n]+esp\.img[^\n]+', fix_entry, text)
idx.write_text(text)
print("flash.idx updated")
EOF
```

### Step 5 — Flash (board still in recovery)

```bash
cd $L4T
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
  --external-device nvme0n1p1 \
  -c tools/kernel_flash/flash_l4t_external.xml \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
  --showlogs --network usb0 \
  --flash-only \
  cti/orin-nano/hadron/base internal
```

This RCM-boots the device with NVIDIA's recovery kernel, brings up USB Ethernet
(192.168.55.1), SSHes in, and writes all QSPI and NVMe partitions. Expect ~4 minutes.
Look for `Flash is successful` and exit code 0.

---

## Partition Image Sources

| Partition | Source |
|---|---|
| QSPI bootloader (MB1/MB2/BPMP/TOS/UEFI/BCT) | L4T BSP (CTI patched, equivalent to Yocto) |
| NVMe kernel + CTI DTB (`boot.img`) | **Yocto tegraflash.tar.gz** |
| NVMe EFI System Partition (`esp.img`) | **Yocto tegraflash.tar.gz** |
| NVMe rootfs (`system.img.zst`) | **Yocto** `hadron-image-base.ext4` (zstd-compressed) |

The Yocto `tegraflash.tar.gz` contains CTI-specific bootloader configs (MB2-BCT with
`cvb_eeprom_read_size=0`, pinmux, gpioint, SCR). These are equivalent to what CTI's
`install.sh` deploys into the L4T BSP.

---

## Default Login Credentials

| User | Password | Notes |
|---|---|---|
| `ubuntu` | `ubuntu` | Has `sudo` access |
| `root` | (locked) | Use `sudo su` from ubuntu |

### Password Hash in Recipe (`hadron-image-base.bb`)

The SHA-512 hash must use **`\$` instead of `$`** in BitBake:

```bitbake
UBUNTU_PASSWD = "\$6\$salt\$hash..."
```

**Why:** `extrausers.bbclass` assigns `EXTRA_USERS_PARAMS` inside a double-quoted shell
string. Bare `$6`, `$f`, `$7...` get shell-expanded to empty, corrupting the hash.
BitBake preserves the backslash; the shell then interprets `\$` as literal `$`.
To regenerate: `openssl passwd -6 ubuntu` — then escape every `$` as `\$` in the recipe.

---

## Why `--network usb0` Works (and `initrd-flash` Doesn't)

| Method | Mechanism | NVMe detection | Result |
|---|---|---|---|
| Yocto `initrd-flash` | USB mass-storage gadget; host writes to NVMe exposed as USB disk | Device-side 15s timeout; `/dev/nvme0n1` never appears | **FAILS** |
| CTI `--network usb0` | USB Ethernet (RNDIS/ECM); host SSHes to 192.168.55.1 and writes NVMe from inside running Linux | NVMe detected normally by recovery kernel | **WORKS** |

---

## CTI BCT Notes

The `tegra234-cti-orin-nx-mb2-bct-misc.dts` sets `cvb_eeprom_read_size=0`, which is
critical for the Hadron board. Without it, MB2 hangs with:
`eeprom: Failed to read I2C slave device`
