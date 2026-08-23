# The Hadron fastboot kernel builds the NVMe root chain in-tree (=y) — see
# recipes-kernel/linux/.../fastboot.cfg. Those drivers are therefore no longer
# produced as loadable kernel-module-* packages, so the stock tegra-minimal-initramfs
# PACKAGE_INSTALL (which hard-lists them) fails do_rootfs with "Unable to find a
# match: kernel-module-nvme ...". Drop them here: the initramfs still loads the
# remaining modules and runs init, while the kernel now mounts nvme root directly.
PACKAGE_INSTALL:remove = "\
    kernel-module-nvme \
    kernel-module-pcie-tegra194 \
    kernel-module-phy-tegra194-p2u \
"
