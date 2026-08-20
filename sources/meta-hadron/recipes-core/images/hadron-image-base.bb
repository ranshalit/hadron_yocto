require recipes-core/images/core-image-base.bb

SUMMARY = "Hadron NGX012 base image"
DESCRIPTION = "Minimal base image for the ConnectTech Hadron NGX012 (Jetson Orin Nano 4GB). \
               Provides static eth0 IP 192.168.132.100/24, ubuntu user with password, \
               BMI160 IIO driver modules, and SSH access."

IMAGE_INSTALL:append = " \
    hadron-network \
    hadron-usb-otg \
    hadron-serial-symlinks \
    kernel-module-bmi160-core \
    kernel-module-bmi160-i2c \
    kernel-module-uvcvideo \
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
    ffmpeg \
    docker-moby \
    nvidia-container-toolkit \
    libwebp \
    gdbserver \
    systemd-analyze \
"

IMAGE_FEATURES:append = " ssh-server-openssh dbg-pkgs"
# Include debug packages and source files in the SDK
SDKIMAGE_FEATURES += "dbg-pkgs src-pkgs"

# Bundle cmake/ninja into the host SDK (populate_sdk) so cross-building cmake
# apps on the host does not depend on the host's own cmake version.
TOOLCHAIN_HOST_TASK:append = " nativesdk-cmake nativesdk-ninja"

# Stage extra libraries that the device image does not need at runtime into the
# SDK target sysroot only (not the flashed image), so host cross-builds can find
# them:
#   * OpenCV contrib modules (datasets/dpm/superres/ts/videostab/xobjdetect):
#     the OpenCV -dev OpenCVModules.cmake references every built module, so
#     without these 6 runtime .so, find_package(OpenCV) aborts with 'imported
#     target opencv_datasets references a file that does not exist'.
#   * serial (wjwwood): a static-only lib (libserial.a in -staticdev, headers +
#     serialConfig.cmake in -dev). The runtime 'serial' package is empty, so it
#     cannot be IMAGE_INSTALL'd; it links statically into apps that need it.
# Keeping these SDK-only leaves the flashed image lean.
TOOLCHAIN_TARGET_TASK:append = " \
    libopencv-datasets-dev \
    libopencv-dpm-dev \
    libopencv-superres-dev \
    libopencv-ts-dev \
    libopencv-videostab-dev \
    libopencv-xobjdetect-dev \
    serial-dev \
    serial-staticdev \
"

inherit extrausers

# SHA-512 crypt hash of 'ubuntu'. Regenerate with: openssl passwd -6 ubuntu
# The \$ escapes are required: see comment above UBUNTU_PASSWD definition.
# The \$ escapes are required: extrausers.bbclass assigns EXTRA_USERS_PARAMS inside
# a double-quoted shell string, so bare $ signs get shell-expanded to empty.
# BitBake preserves the backslash; the shell then interprets \$ as literal $.
UBUNTU_PASSWD = "\$6\$f/BmnEoofLFK53F3\$7ZIR6XHL5SjDszGcFaaX5FY0lGEjsMtJf3x7y.rl3f4meKmcLnPtgoFRp6xwdgFRQZZYnLmX674/PrG93EOvQ/"

EXTRA_USERS_PARAMS = "\
    useradd -m -s /bin/bash -G sudo,video,dialout ubuntu; \
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
    echo "$(date -u +"%Y-%m-%d %H:%M:%S")" >> ${IMAGE_ROOTFS}${sysconfdir}/wasp/version/version.txt
}
