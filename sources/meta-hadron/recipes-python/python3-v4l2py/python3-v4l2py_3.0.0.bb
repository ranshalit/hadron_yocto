SUMMARY = "Human friendly video for linux"
HOMEPAGE = "https://github.com/tiagocoutinho/v4l2py"
LICENSE = "GPL-3.0-or-later"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1ebbd3e34237af26da5dc08a4e440464"

inherit pypi setuptools3

SRC_URI[sha256sum] = "7e83c02f7393da883c791b9b7ba3dd11163b42d15e68dc09b3e3d99a6d75b7a4"

RDEPENDS:${PN} += "python3-linuxpy"

BBCLASSEXTEND = "native nativesdk"
