SUMMARY = "BMI160 IMU runtime configuration for Hadron NGX012"
DESCRIPTION = "Installs a modules-load.d fragment to autoload bmi160_i2c at boot, \
               and a udev rule to instantiate the BMI160 on i2c-7 at address 0x69 \
               (SDO=VCC wiring on the Hadron NGX012 40-pin expansion header)."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "(hadron-ngx012)"

SRC_URI = " \
    file://bmi160.conf \
    file://99-bmi160.rules \
"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/modules-load.d
    install -m 0644 ${WORKDIR}/bmi160.conf ${D}${sysconfdir}/modules-load.d/

    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/99-bmi160.rules ${D}${sysconfdir}/udev/rules.d/
}

FILES:${PN} = " \
    ${sysconfdir}/modules-load.d/bmi160.conf \
    ${sysconfdir}/udev/rules.d/99-bmi160.rules \
"
