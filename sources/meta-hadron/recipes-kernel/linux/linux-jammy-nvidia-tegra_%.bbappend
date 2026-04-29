FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}:"
SRC_URI:append = " file://bmi160.cfg"
KERNEL_CONFIG_FRAGMENTS:append = " ${WORKDIR}/bmi160.cfg"
