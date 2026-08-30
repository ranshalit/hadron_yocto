SUMMARY = "Stable serial device symlinks for Hadron NGX012 peripherals"
DESCRIPTION = "Installs udev rules that create persistent /dev symlinks for USB \
serial peripherals: ttyCAM for the UART camera (USB vendor 5353) and ttyPixHawk \
for the CubePilot Orange Cube flight controller (2dae:1058, interface 00). Also \
sets the latency_timer to 1 for FTDI USB-serial adapters (ftdi_sio driver)."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "(hadron-ngx012)"

SRC_URI = " \
    file://99-cam.rules \
    file://99-orangecube.rules \
    file://99-ftdi-latency.rules \
"

S = "${WORKDIR}"

RDEPENDS:${PN} = "udev"

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/99-cam.rules ${D}${sysconfdir}/udev/rules.d/99-cam.rules
    install -m 0644 ${WORKDIR}/99-orangecube.rules ${D}${sysconfdir}/udev/rules.d/99-orangecube.rules
    install -m 0644 ${WORKDIR}/99-ftdi-latency.rules ${D}${sysconfdir}/udev/rules.d/99-ftdi-latency.rules
}

FILES:${PN} = " \
    ${sysconfdir}/udev/rules.d/99-cam.rules \
    ${sysconfdir}/udev/rules.d/99-orangecube.rules \
    ${sysconfdir}/udev/rules.d/99-ftdi-latency.rules \
"
