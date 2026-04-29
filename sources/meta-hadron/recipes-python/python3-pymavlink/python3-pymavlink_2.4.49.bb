SUMMARY = "Python MAVLink interface and utilities"
HOMEPAGE = "https://github.com/ArduPilot/pymavlink"
LICENSE = "LGPL-3.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6ea13ec5f0f3dd35ac5b53afdc3ed9ff"

inherit pypi setuptools3

SRC_URI[sha256sum] = "d7cf10d5592d038a18aa972711177ebb88be2143efcc258df630b0513e9da2c2"

# pymavlink includes a Cython extension (dfindexer); the sdist ships a pre-built
# .c file so Cython is only needed if the .pyx needs to be regenerated.
DEPENDS += "python3-cython-native"

# fastcrc (Rust/maturin) is listed in setup.py install_requires but pymavlink
# provides a pure-Python CRC fallback when fastcrc is unavailable.
# We intentionally omit fastcrc from RDEPENDS to avoid requiring the Rust toolchain.
RDEPENDS:${PN} += "python3-lxml"

BBCLASSEXTEND = "native nativesdk"
