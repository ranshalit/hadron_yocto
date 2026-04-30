require recipes-core/images/hadron-image-base.bb

SUMMARY = "Hadron NGX012 desktop image with NoMachine remote access"
DESCRIPTION = "Extends hadron-image-base with the NoMachine server (nxserver) and \
               XFCE4 desktop environment for headless remote desktop access. \
               Connect from any host using the free NoMachine client (downloads.nomachine.com) \
               to the device IP on port 4000."

IMAGE_INSTALL:append = " \
    nomachine \
    packagegroup-xfce-base \
"

# Explicitly set multi-user.target via symlink — same technique as the Ubuntu
# chroot-based plan: don't call systemctl in a non-booted rootfs.
# Prevents packagegroup-xfce-base from accidentally pulling in graphical.target.
ROOTFS_POSTPROCESS_COMMAND:append = " set_multiuser_target;"
set_multiuser_target() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    ln -sf /lib/systemd/system/multi-user.target \
        ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/default.target
}
