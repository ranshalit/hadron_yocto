SUMMARY = "NoMachine remote desktop server"
HOMEPAGE = "https://www.nomachine.com"
LICENSE = "CLOSED"

# The .deb ships nested tarballs (nxserver/nxnode/nxrunner/nxplayer) under
# /usr/share/NX/packages/server/ — the real binaries live inside those.
# unpack=0: keep the .deb in DL_DIR so we can extract it manually with dpkg-deb.
SRC_URI = "https://download.nomachine.com/download/9.4/Raspberry/nomachine_9.4.14_1_arm64.deb;name=nomachine;unpack=0;downloadfilename=nomachine_9.4.14_1_arm64.deb \
           file://nxserver-setup.service"
SRC_URI[nomachine.sha256sum] = "3b34641d0fb28bf0bc96e01ab37c84ed8c34ed4a816d794047b85abd536e79ef"

# dpkg-deb is needed to extract the outer .deb at build time
DEPENDS = "dpkg-native"

inherit systemd

# nxserver-setup.service runs first (creates nx user, PAM, certs, node.cfg)
# nxserver.service runs after (depends on nx user existing)
SYSTEMD_SERVICE:${PN} = "nxserver-setup.service nxserver.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# Prebuilt ARM64 binaries — skip stripping and host/target checks
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_SYSROOT_STRIP = "1"
INSANE_SKIP:${PN} = "already-stripped file-rdeps arch textrel ldflags"

# PAM is needed for NoMachine user authentication; xfce4-session provides
# /usr/bin/startxfce4 which we configure as DefaultDesktopCommand
RDEPENDS:${PN} = "libpam shadow xfce4-session"

# Path to the downloaded .deb in the BitBake download cache
NM_DEB = "${DL_DIR}/nomachine_9.4.14_1_arm64.deb"

S = "${WORKDIR}"

do_compile() {
    :
}

do_install() {
    # ── 1. Extract outer .deb into a staging area ─────────────────────────────
    rm -rf ${WORKDIR}/nm-deb
    mkdir -p ${WORKDIR}/nm-deb
    dpkg-deb --extract ${NM_DEB} ${WORKDIR}/nm-deb

    # ── 2. Extract all four nested tarballs to populate /usr/NX/ ─────────────
    # Each tarball uses NX/ as its top-level path, so extracting to ${D}/usr/
    # gives us ${D}/usr/NX/{bin,lib,scripts,etc,...}
    install -d ${D}/usr/NX
    for pkg in server node runner player; do
        tar xzf ${WORKDIR}/nm-deb/usr/share/NX/packages/server/nx${pkg}.tar.gz \
            -C ${D}/usr/
    done

    # ── 3. Install /etc/NX structure ──────────────────────────────────────────
    # /etc/NX/nxserver is the entry-point wrapper: reads server.cfg to find
    # ServerRoot, sets LD_LIBRARY_PATH, and execs nxserver.bin.
    # nxserver.service ExecStart points to this wrapper.
    install -d ${D}${sysconfdir}/NX/server/localhost
    install -m 0755 ${D}/usr/NX/scripts/etc/nxserver \
        ${D}${sysconfdir}/NX/nxserver

    # server.cfg: declares ServerRoot=/usr/NX and NXUserHome=/var/NX/nx/.nx
    install -m 0644 ${WORKDIR}/nm-deb/etc/NX/server/localhost/server.cfg.sample \
        ${D}${sysconfdir}/NX/server/localhost/server.cfg

    # ── 4. Pre-patch node.cfg samples with XFCE4 as desktop command ───────────
    # nxserver --install (first boot) copies the best-match sample to
    # /usr/NX/etc/node.cfg. Patching all samples ensures node.cfg is correct
    # without needing to know which distro profile nxserver will select.
    for f in ${D}/usr/NX/etc/node-*.cfg.sample; do
        [ -e "$f" ] || continue
        sed -i 's|^#DefaultDesktopCommand .*|DefaultDesktopCommand "/usr/bin/startxfce4"|' "$f"
    done

    # ── 5. Install systemd service units ──────────────────────────────────────
    install -d ${D}${systemd_unitdir}/system

    # nxserver.service is bundled in the nxserver tarball
    install -m 0644 ${D}/usr/NX/scripts/systemd/nxserver.service \
        ${D}${systemd_unitdir}/system/nxserver.service

    # Drop-in: guarantee nxserver starts only after first-boot setup completes
    # (nx user and PAM configs must exist before nxserver.service launches)
    install -d ${D}${systemd_unitdir}/system/nxserver.service.d
    printf '[Unit]\nAfter=nxserver-setup.service\nWants=nxserver-setup.service\n' \
        > ${D}${systemd_unitdir}/system/nxserver.service.d/10-after-setup.conf

    # First-boot setup service
    install -m 0644 ${WORKDIR}/nxserver-setup.service \
        ${D}${systemd_unitdir}/system/nxserver-setup.service

    # ── 6. Remove nested tarballs — not needed at runtime, saves ~75 MB ───────
    rm -rf ${D}/usr/share/NX
    rm -rf ${D}/usr/share/doc
}

FILES:${PN} = " \
    /usr/NX \
    ${sysconfdir}/NX \
    ${systemd_unitdir}/system/nxserver.service \
    ${systemd_unitdir}/system/nxserver.service.d \
    ${systemd_unitdir}/system/nxserver-setup.service \
"
