require recipes-core/images/hadron-image-base.bb

SUMMARY = "Hadron NGX012 fastboot image"
DESCRIPTION = "Boots to ICMP-ready fastest. Keeps docker, nvidia-container-toolkit, \
               ffmpeg, pymavlink, wasp; drops CUDA/opencv/full-gstreamer so the rootfs \
               is smaller and fewer services sit on the boot critical path. Heavy \
               workloads start AFTER first ping."

# Remove payload not needed at/after ping (pulled in by hadron-image-base via its
# IMAGE_INSTALL:append). docker/ffmpeg/pymavlink/nvidia-container-toolkit stay.
IMAGE_INSTALL:remove = " \
    python3-opencv \
    python3-v4l2py \
    gstreamer1.0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-python \
"

# The base image ships SDK/debug tooling that only matters on a developer image.
# A fastboot production image does not need on-device debug symbols.
IMAGE_FEATURES:remove = "dbg-pkgs"
