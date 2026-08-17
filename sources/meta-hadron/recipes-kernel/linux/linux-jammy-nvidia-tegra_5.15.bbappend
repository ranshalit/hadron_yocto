FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# CTI Hadron in-tree kernel deltas (from CTI L4T 36.4.4-V005 source) that the
# OE4T meta-tegra kernel lacks. Required so the OTG (usb2-0) port works in host
# mode on the Hadron carrier, whose VBUS/ID sense GPIOs are wired inverted and
# whose DTB uses the CTI-custom cti,vbus-invert / cti,id-invert properties.
SRC_URI:append = " \
    file://0001-cti-usb-conn-gpio-vbus-id-invert.patch \
    file://0002-cti-xusb-tegra186-keep-vbus-id-override.patch \
"
