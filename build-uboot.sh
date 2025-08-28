#!/bin/bash
: "${BOARD:=all}"
: "${UBOOT_DIR:=src/u-boot}"
: "${TFA_DIR:=src/tfa}"
: "${RKBIN_DIR:=src/rkbin}"
: "${KEEP_SRC:=no}"
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"

# Use the Github mirror by default, as it has beefier infrastructure vs. denx.de
: "${UBOOT_GIT:=https://github.com/u-boot/u-boot.git}"
: "${UBOOT_BRANCH:=master}"

: "${TFA_GIT:=https://github.com/ARM-software/arm-trusted-firmware.git}"
: "${TFA_BRANCH:=master}"

: "${RKBIN_GIT:=https://github.com/radxa/rkbin}"
: "${RKBIN_BRANCH:=develop-v2025.04}"

: "${USE_BL31:=opensource}"

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

[ ! -d "$UBOOT_DIR" ] && git clone --depth 1 -b "$UBOOT_BRANCH" "$UBOOT_GIT" "$UBOOT_DIR"
[ ! -d "$RKBIN_DIR" ] && git clone --depth 1 -b "$RKBIN_BRANCH" "$RKBIN_GIT" "$RKBIN_DIR"
[ ! -d "$TFA_DIR" ] && [ x"$USE_BL31" = x"opensource" ] && git clone --depth 1 -b "$TFA_BRANCH" "$TFA_GIT" "$TFA_DIR"

ROCKCHIP_TPL=`realpath "$RKBIN_DIR"/bin/rk35/rk3576_ddr_*.bin | tail -n1`
BL31=

if [ x"$USE_BL31" = x"opensource" ]; then
	pushd "$TFA_DIR"
	make PLAT=rk3576 -j$(nproc) clean
	make PLAT=rk3576 -j$(nproc)
	popd
	BL31=`realpath "$TFA_DIR"/build/rk3576/release/bl31/bl31.elf`
else
	BL31=`realpath "$RKBIN_DIR"/bin/rk35/rk3576_bl31_*.elf`
fi

pushd "$RKBIN_DIR"
rm -f rk3576_spl_loader_*.bin
./tools/boot_merger RKBOOT/RK3576MINIALL.ini
popd

if [ x"$BOARD" = x"all" ]; then
	BOARDS=`basename -a -s "-rk3576_defconfig" "$UBOOT_DIR"/configs/*-rk3576_defconfig`
else
	BOARDS="$BOARD"
fi

for i in $BOARDS; do
	pushd "$UBOOT_DIR"
	make -j$(nproc) CROSS_COMPILE="$CROSS_COMPILE" clean
	make -j$(nproc) CROSS_COMPILE="$CROSS_COMPILE" "$i"-rk3576_defconfig
	make -j$(nproc) CROSS_COMPILE="$CROSS_COMPILE" BL31="$BL31" ROCKCHIP_TPL="$ROCKCHIP_TPL"
	popd

	rm -rf "$UBOOT_OUT"/"$i"
	mkdir -p "$UBOOT_OUT"/"$i"
	cp "$UBOOT_DIR"/u-boot-rockchip*.bin "$UBOOT_OUT"/"$i"/
	cp "$RKBIN_DIR"/rk3576_spl_loader_*.bin "$UBOOT_OUT"/"$i"
done
