SUMMARY = "Static IP configuration for eth0 on Hadron NGX012"
DESCRIPTION = "Installs a systemd-networkd .network file that assigns \
               192.168.132.100/24 as a static address on eth0, and enables \
               systemd-networkd.service at boot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

SRC_URI = "file://10-eth0.network"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${WORKDIR}/10-eth0.network ${D}${sysconfdir}/systemd/network/

    # Enable systemd-networkd at boot — equivalent to 'systemctl enable systemd-networkd'.
    # The service unit is installed by the systemd package (PACKAGECONFIG[networkd]).
    install -d ${D}${sysconfdir}/systemd/system/multi-user.target.wants
    ln -sf ${systemd_unitdir}/system/systemd-networkd.service \
        ${D}${sysconfdir}/systemd/system/multi-user.target.wants/systemd-networkd.service
}

FILES:${PN} = " \
    ${sysconfdir}/systemd/network/10-eth0.network \
    ${sysconfdir}/systemd/system/multi-user.target.wants/systemd-networkd.service \
"
RDEPENDS:${PN} = "systemd"
