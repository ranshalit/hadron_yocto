require recipes-core/images/core-image-base.bb

SUMMARY = "Hadron NGX012 base image"
DESCRIPTION = "Minimal base image for the ConnectTech Hadron NGX012 (Jetson Orin Nano 4GB). \
               Provides static eth0 IP 192.168.132.100/24, ubuntu user with password, \
               BMI160 IIO driver modules, and SSH access."

IMAGE_INSTALL:append = " \
    hadron-network \
    kernel-module-bmi160-core \
    kernel-module-bmi160-i2c \
    sudo \
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
