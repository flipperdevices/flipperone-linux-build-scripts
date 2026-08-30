#!/bin/bash
set -e

# Determine build target (default: all)
BUILD_TARGET="${BUILD_TARGET:-all}"

cd /flipperone-linux-build-scripts

case "${BUILD_TARGET}" in
    all)
        ./build-uboot.sh
        ./build-kernel-mainline.sh
        ./build-kernel-bsp.sh
        ./build-ospack.sh
        ./build-rootfs-img.sh
        ./build-images.sh
        ./build-dtbo.sh
        ;;
    uboot)
        ./build-uboot.sh
        ;;
    kernel-mainline)
        ./build-kernel-mainline.sh
        ;;
    kernel-bsp)
        ./build-kernel-bsp.sh
        ;;
    ospack)
        ./build-ospack.sh
        ;;
    rootfs-img)
        ./build-rootfs-img.sh
        ;;
    images)
        ./build-images.sh
        ;;
    *)
        echo "Unknown BUILD_TARGET: ${BUILD_TARGET}"
        echo "Valid targets: all, uboot, kernel-mainline, kernel-bsp, ospack, rootfs-img, images"
        exit 1
        ;;
esac
