# Same reason as tegra-minimal-initramfs.bbappend: the Hadron fastboot kernel
# builds NVMe/PCIe/PHY in-tree (=y), so these kernel-module-* packages no longer
# exist. This flashing initramfs pulls them (as hard installs) via
# MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS expanded into PACKAGE_INSTALL, so do_rootfs
# fails with "Unable to find a match: kernel-module-nvme ...". Drop them — the
# flasher kernel now has the NVMe stack built in.
PACKAGE_INSTALL:remove = "\
    kernel-module-nvme \
    kernel-module-pcie-tegra194 \
    kernel-module-phy-tegra194-p2u \
"
