# Hadron: build OpenCV without CUDA/DNN — we only need Python bindings.
# meta-tegra's opencv bbappend unconditionally inherits cuda-gcc, which adds
# gcc-for-nvcc-cross as a hard DEPENDS. That recipe fails to compile on the
# Ubuntu 22.04 host (GCC 13.2 rtl_ssa linker errors). Strip those deps here.
DEPENDS:remove = " \
    virtual/aarch64-poky-linux-cuda-gcc \
    gcc-for-nvcc-runtime \
    cuda-compatibility-workarounds \
    cuda-libraries \
    cuda-compiler-native \
    cuda-cudart-native \
    cudnn \
"

# Also ensure the cuda/dnn PackageConfig features are off
PACKAGECONFIG:remove = "cuda dnn"

# Disable the sfm (structure-from-motion) contrib module. It bundles the libmv
# 3rdparty static libs (correspondence/multiview/numeric), which meta-oe builds
# but never installs/packages. OpenCVModules.cmake still imports them, so
# find_package(OpenCV) aborts with 'imported target correspondence references a
# file that does not exist'. Nothing in this BSP uses sfm, so turn it off to
# keep find_package(OpenCV) usable from the SDK.
EXTRA_OECMAKE:append = " -DBUILD_opencv_sfm=OFF"
