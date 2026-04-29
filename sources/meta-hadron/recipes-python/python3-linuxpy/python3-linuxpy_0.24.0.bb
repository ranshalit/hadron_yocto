SUMMARY = "Human friendly interface to linux subsystems using python"
HOMEPAGE = "https://github.com/tiagocoutinho/linuxpy"
LICENSE = "GPL-3.0-or-later"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1ebbd3e34237af26da5dc08a4e440464"

inherit pypi setuptools3

SRC_URI[sha256sum] = "2b44434d28d49257e859a4830267a25aa4b51b1d229f95f79d025ae7f1a5d30e"

RDEPENDS:${PN} += "python3-core"

BBCLASSEXTEND = "native nativesdk"
