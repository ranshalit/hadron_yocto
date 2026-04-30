SUMMARY = "WASP software version identifier for Hadron NGX012"
DESCRIPTION = "Installs /etc/wasp/version/version.txt containing the current \
               WASP software version string. The build timestamp is appended \
               by the image recipe's ROOTFS_POSTPROCESS_COMMAND."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/wasp/version
    echo "${PV}" > ${D}${sysconfdir}/wasp/version/version.txt
}

FILES:${PN} = "${sysconfdir}/wasp/version/version.txt"
