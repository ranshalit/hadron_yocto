require recipes-core/images/hadron-image-base.bb

SUMMARY = "Hadron NGX012 desktop image with X11 remote access"
DESCRIPTION = "Extends hadron-image-base with an XFCE4 desktop environment and \
               SSH X11 forwarding, so X apps (e.g. xclock) can be launched from a \
               host running an X server via: ssh -X ubuntu@<device-ip>; xclock."

IMAGE_INSTALL:append = " \
    packagegroup-xfce-base \
    xclock \
    xauth \
"

# Enable SSH X11 forwarding (ssh -X <ip>). sshd_config already ships
# 'X11Forwarding yes'; xauth (above) provides the auth-cookie handling that
# forwarding requires. With this, a host running an X server can launch X apps
# (e.g. xclock) over: ssh -X ubuntu@<ip>; xclock

# Explicitly set multi-user.target via symlink — same technique as the Ubuntu
# chroot-based plan: don't call systemctl in a non-booted rootfs.
# Prevents packagegroup-xfce-base from accidentally pulling in graphical.target.
ROOTFS_POSTPROCESS_COMMAND:append = " set_multiuser_target;"
set_multiuser_target() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    ln -sf /lib/systemd/system/multi-user.target \
        ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/default.target
}
