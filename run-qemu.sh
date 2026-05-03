#!/bin/bash
# run-qemu.sh — Boot hadron-image-base in QEMU aarch64 virt
#
# Serial layout:
#   QEMU virt only creates one PL011 UART (ttyAMA0) regardless of -serial count.
#   ttyAMA0 carries earlycon + Linux console (ttyTHS1 role in QEMU).
#   ttyTCU0 (bootloader/EFI debug) has no equivalent in direct kernel boot.
#
# Usage:
#   ./run-qemu.sh                      # starts QEMU; tail console.log for boot
#   HADRON_QEMU_LOGS=/my/dir ./run-qemu.sh
#
# In another terminal:
#   tail -f /tmp/hadron-qemu/console.log               # main boot log
#   socat - unix-connect:/tmp/hadron-qemu/console.sock # interactive login

set -euo pipefail

IMAGES=/media/ranshal/jetson/hadron_yocto/build/tmp/deploy/images/hadron-ngx012
KERNEL=$IMAGES/Image
ROOTFS=$IMAGES/hadron-image-base-hadron-ngx012.rootfs.ext4

LOG_DIR=${HADRON_QEMU_LOGS:-/tmp/hadron-qemu}
mkdir -p "$LOG_DIR"

CONSOLE_LOG=$LOG_DIR/console.log
CONSOLE_SOCK=$LOG_DIR/console.sock

rm -f "$CONSOLE_SOCK"
truncate -s 0 "$CONSOLE_LOG"

cat <<EOF
Hadron QEMU boot
  kernel : $KERNEL
  rootfs : $ROOTFS (snapshot — original unmodified)

Serial socket (interactive login):
  socat - unix-connect:$CONSOLE_SOCK

Log file (tail boot):
  tail -f $CONSOLE_LOG

Starting QEMU... (Ctrl+C to stop)
EOF

exec qemu-system-aarch64 \
    -M virt,gic-version=3 \
    -cpu max \
    -m 4096 \
    -smp 4 \
    -kernel "$KERNEL" \
    -drive if=virtio,file="$ROOTFS",format=raw,cache=unsafe,snapshot=on \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -append "root=/dev/vda rw rootfstype=ext4 rootwait earlycon=pl011,mmio32,0x09000000 console=ttyAMA0,115200 mminit_loglevel=4 firmware_class.path=/etc/firmware loglevel=4 no_console_suspend systemd.mask=dev-disk-by\\x2dpartlabel-esp.device" \
    -chardev "socket,id=serial0,path=$CONSOLE_SOCK,server=on,wait=off,logfile=$CONSOLE_LOG" \
    -serial chardev:serial0 \
    -display none \
    -monitor none \
    -no-reboot
