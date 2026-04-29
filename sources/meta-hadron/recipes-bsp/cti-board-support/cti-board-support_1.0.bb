SUMMARY = "ConnectTech Hadron NGX012 precompiled DTB and BCT files"
DESCRIPTION = "Precompiled board DTB, module SKU overlay, and carrier pinmux BCT \
               for the ConnectTech Hadron NGX012 with Jetson Orin Nano 4GB (p3767-0003). \
               Extracted from CTI-L4T-ORIN-NX-NANO-36.4.4-V005. \
               Provides virtual/dtb to replace the default nvidia-kernel-oot-dtb provider."

LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://tegra234-cti-orin-nx-hadron-mb1-bct-pinmux.dtsi;beginline=2;endline=30;md5=49a3d389b4cc6171016e4aaed0056bfc"

PACKAGE_ARCH = "${MACHINE_ARCH}"
COMPATIBLE_MACHINE = "(hadron-ngx012)"

PROVIDES += "virtual/dtb"

# file:// SRC_URI entries unpack to ${WORKDIR}; S must match so LIC_FILES_CHKSUM resolves correctly.
S = "${WORKDIR}"

SRC_URI = "file://tegra234-orin-nano-cti-NGX012.dtb \
           file://tegra234-cti-orin-nano-0003-nv-super-overlay.dtbo \
           file://tegra234-cti-orin-nx-hadron-mb1-bct-pinmux.dtsi \
           file://tegra234-cti-orin-nx-mb2-bct-misc.dts \
           file://tegra234-cti-orin-nx-mb1-bct-gpioint.dts \
           file://tegra234-cti-orin-nx-mb2-bct-scr.dts"

# /boot is not in the default SYSROOT_DIRS. Adding it makes /boot/devicetree/ visible
# to image_types_tegra.bbclass via EXTERNAL_KERNEL_DEVICETREE = "${RECIPE_SYSROOT}/boot/devicetree".
SYSROOT_DIRS += "/boot"

do_install() {
    install -d ${D}/boot/devicetree
    install -m 0644 ${WORKDIR}/tegra234-orin-nano-cti-NGX012.dtb ${D}/boot/devicetree/
    install -m 0644 ${WORKDIR}/tegra234-cti-orin-nano-0003-nv-super-overlay.dtbo ${D}/boot/devicetree/

    # Pinmux DTSI for tegraflash BCT generation.
    # tegraflash_populate_package globs tegra234-*.dts* from ${STAGING_DATADIR}/tegraflash/.
    install -d ${D}${datadir}/tegraflash
    install -m 0644 ${WORKDIR}/tegra234-cti-orin-nx-hadron-mb1-bct-pinmux.dtsi ${D}${datadir}/tegraflash/

    # CTI BCT overrides for MB2 (disables missing carrier EEPROM read), GPIO interrupts, SCR.
    install -m 0644 ${WORKDIR}/tegra234-cti-orin-nx-mb2-bct-misc.dts    ${D}${datadir}/tegraflash/
    install -m 0644 ${WORKDIR}/tegra234-cti-orin-nx-mb1-bct-gpioint.dts ${D}${datadir}/tegraflash/
    install -m 0644 ${WORKDIR}/tegra234-cti-orin-nx-mb2-bct-scr.dts     ${D}${datadir}/tegraflash/
}

FILES:${PN} = "/boot/devicetree ${datadir}/tegraflash"
