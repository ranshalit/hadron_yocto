FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}:"
SRC_URI:append = " file://bmi160.cfg file://fastboot.cfg"
KERNEL_CONFIG_FRAGMENTS:append = " ${WORKDIR}/bmi160.cfg ${WORKDIR}/fastboot.cfg"
