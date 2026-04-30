require recipes-core/images/core-image-base.bb

SUMMARY = "Hadron NGX012 base image"
DESCRIPTION = "Minimal base image for the ConnectTech Hadron NGX012 (Jetson Orin Nano 4GB). \
               Provides static eth0 IP 192.168.132.100/24, ubuntu user with password, \
               BMI160 IIO driver modules, and SSH access."

IMAGE_INSTALL:append = " \
    hadron-network \
    kernel-module-bmi160-core \
    kernel-module-bmi160-i2c \
    bmi160-config \
    iproute2 \
    net-tools \
    sudo \
    gstreamer1.0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-python \
    python3-opencv \
    boost \
    libxml2 \
    python3-pyserial \
    python3-cython \
    python3-psutil \
    python3-pymavlink \
    python3-v4l2py \
    wasp-version \
    hadron-serial-switch \
"

IMAGE_FEATURES:append = " ssh-server-openssh"

inherit extrausers

# SHA-512 crypt hash of 'ubuntu'. Regenerate with: openssl passwd -6 ubuntu
# The \$ escapes are required: see comment above UBUNTU_PASSWD definition.
# The \$ escapes are required: extrausers.bbclass assigns EXTRA_USERS_PARAMS inside
# a double-quoted shell string, so bare $ signs get shell-expanded to empty.
# BitBake preserves the backslash; the shell then interprets \$ as literal $.
UBUNTU_PASSWD = "\$6\$f/BmnEoofLFK53F3\$7ZIR6XHL5SjDszGcFaaX5FY0lGEjsMtJf3x7y.rl3f4meKmcLnPtgoFRp6xwdgFRQZZYnLmX674/PrG93EOvQ/"

EXTRA_USERS_PARAMS = "\
    useradd -m -s /bin/bash -G sudo ubuntu; \
    usermod -p '${UBUNTU_PASSWD}' ubuntu; \
"

# Yocto's default sudoers does not grant the sudo group access — add it explicitly.
# Also add /sbin:/usr/sbin to PATH for all users (Yocto only adds them for root).
ROOTFS_POSTPROCESS_COMMAND:append = " setup_sudo_group; setup_sbin_path; stamp_wasp_version;"
setup_sudo_group() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/sudoers.d
    echo '%sudo ALL=(ALL:ALL) ALL' > ${IMAGE_ROOTFS}${sysconfdir}/sudoers.d/sudo-group
    chmod 440 ${IMAGE_ROOTFS}${sysconfdir}/sudoers.d/sudo-group
}
setup_sbin_path() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/profile.d
    echo 'export PATH="$PATH:/usr/sbin:/sbin"' > ${IMAGE_ROOTFS}${sysconfdir}/profile.d/sbin-path.sh
}
# Append the image build timestamp as the second line of /etc/wasp/version/version.txt.
# Runs every do_rootfs so the date always reflects the actual image build time.
stamp_wasp_version() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ${IMAGE_ROOTFS}${sysconfdir}/wasp/version/version.txt
}
