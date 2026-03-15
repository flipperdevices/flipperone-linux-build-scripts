#!/bin/bash
# Combined build script with board configurations
# Builds U-Boot, Linux kernel, and disk images for RK3576 boards

# Load default configuration
COMBO_CONFIG="${COMBO_CONFIG:-configs/combo.conf}"
if [ -f "$COMBO_CONFIG" ]; then
    source "$COMBO_CONFIG"
fi

# Allow environment variables to override config file defaults
: "${UBOOT_DIR:=src/u-boot}"
: "${TFA_DIR:=src/tfa}"
: "${RKBIN_DIR:=src/rkbin}"
: "${KEEP_SRC:=no}"
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${CONFIGS_DIR:=configs/boards}"

: "${LINUX_DIR:=src/linux}"
: "${VENDOR_DTS:=vendor-dts}"
: "${LINUX_OUT:=prebuilt/linux}"
: "${BASE_CONFIG:=configs/minconfig-mainline}"
: "${CONFIGS:=configs/linux}"
: "${LINUX_GIT:=https://github.com/flipperdevices/flipper-linux-kernel.git}"
: "${LINUX_BRANCH:=flipper-devel}"

: "${IMG_OUT:=out}"
: "${IMGSIZE:=4GiB}"

: "${BUILD_UBOOT:=yes}"
: "${BUILD_KERNEL:=yes}"
: "${BUILD_IMAGES:=yes}"

: "${TFA_GIT:=https://github.com/ARM-software/arm-trusted-firmware.git}"
: "${TFA_BRANCH:=master}"
: "${RKBIN_GIT:=https://github.com/radxa/rkbin}"
: "${RKBIN_BRANCH:=develop-v2025.04}"

show_help() {
    cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Combined build script for RK3576 boards with board configurations.

Commands:
    list                List all available board configurations
    build-all           Build U-Boot, kernel, and images for all boards
    build <board>       Build U-Boot, kernel, and images for specific board
    uboot-all           Build only U-Boot for all boards
    uboot <board>       Build only U-Boot for specific board
    kernel              Build only Linux kernel (shared for all boards)
    images              Build only disk images (requires U-Boot and kernel)
    help                Show this help message

Options:
    KEEP_SRC=yes|no|update      Keep/update source directories (default: no)
    IMGSIZE=<size>              Disk image size (default: 4GiB)
    UPDATE_ROOTFS=yes           Force rebuild of root filesystem
    COMBO_CONFIG=<path>         Path to combo.conf (default: configs/combo.conf)

Examples:
    $0 list                  # List all board configurations
    $0 build rock-4d         # Build everything for rock-4d
    $0 build-all             # Build everything for all boards
    $0 uboot rock-4d         # Build only U-Boot for rock-4d
    $0 kernel                # Build only Linux kernel
    $0 images                # Build only disk images

    KEEP_SRC=yes $0 build-all      # Build all, keep sources
    IMGSIZE=8GiB $0 build rock-4d  # Build with 8GB images

Available boards:
EOF
    ./configs/board-config.sh list 2>/dev/null | tail -n +3 || echo "  (Run './configs/board-config.sh list' to see boards)"
}

set -e

# Function to load board configuration
load_board_config() {
    local board="$1"
    local config_file="$CONFIGS_DIR/${board}.conf"

    if [ ! -f "$config_file" ]; then
        echo "Error: Board configuration not found: $config_file" >&2
        return 1
    fi

    echo "Loading configuration for $board from $config_file"
    source "$config_file"

    # Export variables that may be used by the build process
    export BOARD_NAME
    export UBOOT_DEFCONFIG
    export UBOOT_GIT
    export UBOOT_BRANCH
    export USE_BL31
}

# Function to get list of all available boards from config files
get_available_boards() {
    local boards=""
    for conf in "$CONFIGS_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        local board_id=$(basename "$conf" .conf)
        boards="$boards $board_id"
    done
    echo $boards
}

# Function to discover boards that have defconfigs in U-Boot tree
discover_boards_with_defconfig() {
    local uboot_dir="$1"
    local boards=""

    if [ ! -d "$uboot_dir/configs" ]; then
        echo "" >&2
        return
    fi

    for conf in "$CONFIGS_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        local board_id=$(basename "$conf" .conf)

        # Load config to get defconfig name
        (
            source "$conf"
            if [ -f "$uboot_dir/configs/$UBOOT_DEFCONFIG" ]; then
                echo -n "$board_id "
            fi
        )
    done
}

# Parse command-line arguments
COMMAND="${1:-help}"
BOARD_ARG="${2:-}"

case "$COMMAND" in
    list)
        exec ./configs/board-config.sh list
        ;;
    help|--help|-h)
        show_help
        exit 0
        ;;
    build-all)
        BOARD="all"
        BUILD_UBOOT="yes"
        BUILD_KERNEL="yes"
        BUILD_IMAGES="yes"
        ;;
    build)
        if [ -z "$BOARD_ARG" ]; then
            echo "Error: Board name required for 'build' command" >&2
            echo "Usage: $0 build <board>" >&2
            exit 1
        fi
        BOARD="$BOARD_ARG"
        BUILD_UBOOT="yes"
        BUILD_KERNEL="yes"
        BUILD_IMAGES="yes"
        ;;
    uboot-all)
        BOARD="all"
        BUILD_UBOOT="yes"
        BUILD_KERNEL="no"
        BUILD_IMAGES="no"
        ;;
    uboot)
        if [ -z "$BOARD_ARG" ]; then
            echo "Error: Board name required for 'uboot' command" >&2
            echo "Usage: $0 uboot <board>" >&2
            exit 1
        fi
        BOARD="$BOARD_ARG"
        BUILD_UBOOT="yes"
        BUILD_KERNEL="no"
        BUILD_IMAGES="no"
        ;;
    kernel)
        BOARD="all"
        BUILD_UBOOT="no"
        BUILD_KERNEL="yes"
        BUILD_IMAGES="no"
        ;;
    images)
        BOARD="all"
        BUILD_UBOOT="no"
        BUILD_KERNEL="no"
        BUILD_IMAGES="yes"
        ;;
    *)
        echo "Error: Unknown command: $COMMAND" >&2
        echo "" >&2
        show_help
        exit 1
        ;;
esac

# Determine which boards to process
if [ "$BOARD" != "all" ]; then
    load_board_config "$BOARD"
    BOARDS="$BOARD"
else
    # Get list of all boards from config files
    BOARDS=$(get_available_boards)
    echo "All configured boards: $BOARDS"

    # Note: Will check for defconfig existence during build
fi

echo ""
echo "========================================"
echo "RK3576 Combined Build Script"
echo "========================================"
echo "Build stages:"
echo "  U-Boot:  $BUILD_UBOOT"
echo "  Kernel:  $BUILD_KERNEL"
echo "  Images:  $BUILD_IMAGES"
echo "Boards:    $BOARDS"
echo ""

# ========================================
# Stage 1: Build U-Boot for all boards
# ========================================
if [ "$BUILD_UBOOT" = "yes" ]; then
    echo ""
    echo "========================================"
    echo "Stage 1: Building U-Boot"
    echo "========================================"

    # Clone/update common repositories
    for i in "$UBOOT_DIR" "$RKBIN_DIR" "$TFA_DIR"; do
        if [ -d "$i" ]; then
            if [ x"$KEEP_SRC" = x"update" ]; then
                pushd "$i"
                git pull
                popd
            elif [ x"$KEEP_SRC" = x"no" ]; then
                rm -rf "$i"
            fi
        fi
    done

    [ ! -d "$RKBIN_DIR" ] && git clone --depth 1 -b "$RKBIN_BRANCH" "$RKBIN_GIT" "$RKBIN_DIR"

    # Build U-Boot for each board
    for board in $BOARDS; do
        echo ""
        echo "----------------------------------------"
        echo "Building U-Boot for: $board"
        echo "----------------------------------------"

        # Load board-specific configuration
        load_board_config "$board"

        echo "Board: $BOARD_FULL_NAME ($BOARD_VENDOR)"
        echo "U-Boot repository: $UBOOT_GIT"
        echo "U-Boot branch: $UBOOT_BRANCH"
        echo "Defconfig: $UBOOT_DEFCONFIG"
        echo "BL31 type: $USE_BL31"

        # Clone U-Boot if needed (board-specific repo)
        if [ ! -d "$UBOOT_DIR" ]; then
            git clone --depth 1 -b "$UBOOT_BRANCH" "$UBOOT_GIT" "$UBOOT_DIR"
        fi

        # Check if defconfig exists
        if [ ! -f "$UBOOT_DIR/configs/$UBOOT_DEFCONFIG" ]; then
            echo "⚠ Warning: Defconfig not found: $UBOOT_DEFCONFIG"
            echo "⚠ Skipping $BOARD_NAME - defconfig doesn't exist in U-Boot tree"
            continue
        fi

        # Build TF-A or prepare vendor BL31
        ROCKCHIP_TPL=`realpath "$RKBIN_DIR"/bin/rk35/rk3576_ddr_*.bin | tail -n1`
        BL31=

        if [ x"$USE_BL31" = x"opensource" ]; then
            if [ ! -d "$TFA_DIR" ]; then
                git clone --depth 1 -b "$TFA_BRANCH" "$TFA_GIT" "$TFA_DIR"
            fi
            pushd "$TFA_DIR"
            make PLAT=rk3576 -j$(nproc) clean
            make PLAT=rk3576 -j$(nproc)
            popd
            BL31=`realpath "$TFA_DIR"/build/rk3576/release/bl31/bl31.elf`
        else
            BL31=`realpath "$RKBIN_DIR"/bin/rk35/rk3576_bl31_v*.elf`
        fi

        # Build boot loaders
        pushd "$RKBIN_DIR"
        rm -f rk3576_spl_loader_*.bin
        ./tools/boot_merger RKBOOT/RK3576MINIALL.ini
        ./tools/boot_merger RKBOOT/RK3576MINIALL_FSPI1.ini
        popd

        # Build U-Boot
        pushd "$UBOOT_DIR"
        make -j$(nproc) CROSS_COMPILE="$CROSS_COMPILE" clean
        make -j$(nproc) CROSS_COMPILE="$CROSS_COMPILE" "$UBOOT_DEFCONFIG"
        make -j$(nproc) CROSS_COMPILE="$CROSS_COMPILE" BL31="$BL31" ROCKCHIP_TPL="$ROCKCHIP_TPL"
        popd

        # Copy outputs
        mkdir -p "$UBOOT_OUT"/"$BOARD_NAME"
        rm -rf "$UBOOT_OUT"/"$BOARD_NAME"
        mkdir -p "$UBOOT_OUT"/"$BOARD_NAME"
        cp "$UBOOT_DIR"/u-boot-rockchip*.bin "$UBOOT_OUT"/"$BOARD_NAME"/
        cp "$RKBIN_DIR"/rk3576_spl_loader_*.bin "$UBOOT_OUT"/"$BOARD_NAME"

        echo "✓ U-Boot build complete for $BOARD_NAME"
    done

    echo ""
    echo "✓ Stage 1 complete: U-Boot built for all boards"
fi

# ========================================
# Stage 2: Build Linux Kernel (once for all boards)
# ========================================
if [ "$BUILD_KERNEL" = "yes" ]; then
    echo ""
    echo "========================================"
    echo "Stage 2: Building Linux Kernel"
    echo "========================================"

    # Clone/update kernel
    if [ -d "$LINUX_DIR" ]; then
        if [ x"$KEEP_SRC" = x"update" ]; then
            pushd "$LINUX_DIR"
            git pull
            popd
        elif [ x"$KEEP_SRC" = x"no" ]; then
            rm -rf "$LINUX_DIR"
        fi
    fi

    [ ! -d "$LINUX_DIR" ] && git clone --depth 1 -b "$LINUX_BRANCH" "$LINUX_GIT" "$LINUX_DIR"

    BASE_CONFIG=`realpath "$BASE_CONFIG"`
    CONFIGS=`realpath "$CONFIGS"/*`

    # Create versioned boot logo
    KVER=`make -C "$LINUX_DIR" -s kernelversion`
    if [ -f flipper_linux_boot_logo_clean.ppm ]; then
        magick flipper_linux_boot_logo_clean.ppm -font haxrcorp-4089-cyrillic-altgr.ttf -pointsize 31 -fill '#ff8200' -gravity SouthEast -annotate +0+0 "Flipper Linux Kernel $KVER" -compress none "$LINUX_DIR"/drivers/video/logo/flipper_linux_boot_logo_versioned.ppm
    fi

    # Build kernel
    pushd "$LINUX_DIR"
    make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) clean
    ./scripts/kconfig/merge_config.sh -m "$BASE_CONFIG" "$CONFIGS"
    make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) olddefconfig
    make ARCH=arm64 DTC_FLAGS="-@" CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) bindeb-pkg

    rm -rf tar-install
    make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) dir-pkg
    pushd tar-install
    tar czf ../modules.tar.gz ./lib
    popd
    popd

    # Copy outputs
    mkdir -p "$LINUX_OUT"/linux-mainline-files/dtbs
    mv "$LINUX_DIR"/../linux-*.* "$LINUX_OUT"/
    mv "$LINUX_DIR"/modules.tar.gz "$LINUX_OUT"/linux-mainline-files/
    mv "$LINUX_DIR"/tar-install/boot/vmlinuz-* "$LINUX_OUT"/linux-mainline-files/vmlinuz
    mv "$LINUX_DIR"/tar-install/boot/config-* "$LINUX_OUT"/linux-mainline-files/config

    echo ""
    echo "✓ Stage 2 complete: Linux kernel built"
fi

# ========================================
# Stage 3: Build Disk Images
# ========================================
if [ "$BUILD_IMAGES" = "yes" ]; then
    echo ""
    echo "========================================"
    echo "Stage 3: Building Disk Images"
    echo "========================================"

    TIMESTAMP=`date -u '+%Y%m%d-%H%M'`
    : "${BUILD_ID:=$TIMESTAMP}"

    mkdir -p "$IMG_OUT"

    # Build rootfs if needed
    if [ ! -f "$IMG_OUT"/debian-rootfs.img.zst -o "$UPDATE_ROOTFS" ]; then
        echo "Building root filesystem..."
        ./build-rootfs-img.sh
    fi

    TMPDIR=`mktemp -d`

    for s in 512 4096; do
        echo ""
        echo "Creating images for $s-byte sector size"
        truncate -s "$IMGSIZE" "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img

        if [ -c /dev/kvm -a -w /dev/kvm ]; then
            cp -f partitions-script.sh "$IMG_OUT"/partitions-script.sh
            fakemachine \
                -b kvm \
                -S "$s" \
                -i "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img \
                -e IMG:/artifacts/debian-rootfs.img.zst \
                -e DISK:/dev/disk/by-fakemachine-label/fakedisk-0 \
                -e PART:/dev/disk/by-fakemachine-label/fakedisk-0-part2 \
                -e BUILD_ID:\""$BUILD_ID"\" \
                -v "$IMG_OUT":/artifacts \
                -- /artifacts/partitions-script.sh
            rm -f "$IMG_OUT"/partitions-script.sh
        else
            LOOPDEV=`sudo losetup -b "$s" -fP --show "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img`
            sudo \
                IMG="$IMG_OUT"/debian-rootfs.img.zst \
                DISK="$LOOPDEV" \
                PART="$LOOPDEV"p2 \
                BUILD_ID="$BUILD_ID" \
                ./partitions-script.sh
            sudo losetup -d "$LOOPDEV"
        fi

        # Create board-specific images
        for i in `basename -a "$UBOOT_OUT"/*`; do
            echo ""
            echo "$i board:"
            echo " - Copying the base image"
            cp "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img "$TMPDIR"/debian-"$s"-"$i"-"$BUILD_ID".img
            echo " - Adding a board-specific bootloader"
            dd if="$UBOOT_OUT"/"$i"/u-boot-rockchip.bin of="$TMPDIR"/debian-"$s"-"$i"-"$BUILD_ID".img seek=64 conv=notrunc
            echo " - Creating a block map"
            bmaptool create -o "$IMG_OUT"/debian-"$s"-"$i"-"$BUILD_ID".img.bmap "$TMPDIR"/debian-"$s"-"$i"-"$BUILD_ID".img
            echo " - Compressing the final image"
            pigz -c "$TMPDIR"/debian-"$s"-"$i"-"$BUILD_ID".img > "$IMG_OUT"/debian-"$s"-"$i"-"$BUILD_ID".img.gz
            rm -f "$TMPDIR"/debian-"$s"-"$i"-"$BUILD_ID".img
            echo "✓ Image created: debian-"$s"-"$i"-"$BUILD_ID".img.gz"
        done

        echo ""
        echo "nobootloader image:"
        echo " - Creating a block map"
        bmaptool create -o "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img.bmap "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img
        echo " - Compressing the final image"
        pigz -c "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img > "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img.gz
        rm -f "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img
    done

    rm -rf "$TMPDIR"

    echo ""
    echo "✓ Stage 3 complete: Disk images built"
fi

echo ""
echo "========================================"
echo "✓ All build stages completed!"
echo "========================================"
echo ""
echo "Output locations:"
[ "$BUILD_UBOOT" = "yes" ] && echo "  U-Boot:  $UBOOT_OUT/"
[ "$BUILD_KERNEL" = "yes" ] && echo "  Kernel:  $LINUX_OUT/"
[ "$BUILD_IMAGES" = "yes" ] && echo "  Images:  $IMG_OUT/"
echo ""
