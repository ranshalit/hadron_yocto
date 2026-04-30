SUMMARY = "Script to switch serial console between ttyTHS1 and ttyTCU0"
DESCRIPTION = "Installs hadron-serial-switch, a POSIX sh script that redirects kernel \
               console and systemd serial-getty between ttyTHS1 (carrier physical UART) \
               and ttyTCU0 (SoC Tegra Combined UART debug port). \
               Updates /boot/extlinux/extlinux.conf for the kernel console change \
               (takes effect on next boot) and manages serial-getty immediately. \
               Also installs a udev rule to prevent ModemManager from claiming either port."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

SRC_URI = "file://hadron-serial-switch \
           file://99-hadron-serial.rules \
           file://10-hadron-console.conf"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/hadron-serial-switch ${D}${sbindir}/hadron-serial-switch

    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/99-hadron-serial.rules ${D}${sysconfdir}/udev/rules.d/

    install -d ${D}${sysconfdir}/systemd/journald.conf.d
    install -m 0644 ${WORKDIR}/10-hadron-console.conf ${D}${sysconfdir}/systemd/journald.conf.d/
}

FILES:${PN} = " \
    ${sbindir}/hadron-serial-switch \
    ${sysconfdir}/udev/rules.d/99-hadron-serial.rules \
    ${sysconfdir}/systemd/journald.conf.d/10-hadron-console.conf \
"
