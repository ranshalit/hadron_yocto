#!/bin/sh
# Keep the Tegra xHCI controller powered so OTG-port (usb2-0) hotplug works.
echo on > /sys/bus/platform/devices/3610000.usb/power/control
