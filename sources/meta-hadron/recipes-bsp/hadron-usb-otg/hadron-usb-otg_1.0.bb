SUMMARY = "Keep Tegra xHCI powered so the OTG USB port detects hotplug"
DESCRIPTION = "Installs a udev rule that disables runtime PM on the Tegra xHCI \
controller (3610000.usb). The controller ELPG runtime-suspends when idle and a \
device connect on the OTG port (usb2-0) does not wake it, so devices hotplugged \
on that port are never enumerated. Keeping the controller powered makes both USB \
ports detect devices, matching the CTI/Ubuntu BSP behaviour."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"
COMPATIBLE_MACHINE = "(hadron-ngx012)"

SRC_URI = "file://hadron-usb-otg-keepon.sh \
           file://90-hadron-usb-otg.rules"

S = "${WORKDIR}"

RDEPENDS:${PN} = "udev"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/hadron-usb-otg-keepon.sh ${D}${sbindir}/hadron-usb-otg-keepon.sh

    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/90-hadron-usb-otg.rules ${D}${sysconfdir}/udev/rules.d/90-hadron-usb-otg.rules
}

FILES:${PN} = "${sbindir}/hadron-usb-otg-keepon.sh ${sysconfdir}/udev/rules.d/90-hadron-usb-otg.rules"
