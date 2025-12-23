#!/bin/bash
: "${LINUX_DIR:=src/linux-bsp}"
: "${VENDOR_DTS:=vendor-dts}"
: "${PATCHES_DIR:=patches/bsp}"
: "${KEEP_SRC:=no}"
: "${LINUX_OUT:=prebuilt/linux}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${CONFIGS:=configs/linux-bsp}"

: "${LINUXBSP_GIT:=https://github.com/rockchip-linux/kernel.git}"
: "${LINUXBSP_BRANCH:=develop-6.1}"

set -e

if [ -d "$LINUX_DIR" ]; then
	if [ x"$KEEP_SRC" = x"update" ]; then
		pushd "$LINUX_DIR"
		git reset --hard HEAD
		git pull
		popd
	elif [ x"$KEEP_SRC" = x"no" ]; then
		rm -rf "$LINUX_DIR"
	fi
fi

[ ! -d "$LINUX_DIR" ] && git clone --depth 1 -b "$LINUXBSP_BRANCH" "$LINUXBSP_GIT" "$LINUX_DIR"

if [ ! x"$KEEP_SRC" = x"yes" ]; then
	# For Radxa Rock 4D
	wget -O "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/rk3576-rock-4d.dts \
		https://raw.githubusercontent.com/radxa/kernel/refs/heads/linux-6.1-stan-rkr5.1/arch/arm64/boot/dts/rockchip/rk3576-rock-4d.dts
	echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3576-rock-4d.dtb' >> "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/Makefile

	# For FriendlyELEC NanoPi M5
	wget -O "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/rk3576-nanopi-m5.dts \
		https://raw.githubusercontent.com/friendlyarm/kernel-rockchip/refs/heads/nanopi6-v6.1.y/arch/arm64/boot/dts/rockchip/rk3576-nanopi5-rev01.dts
	wget -O "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/rk3576-nanopi5-common.dtsi \
		https://github.com/friendlyarm/kernel-rockchip/raw/refs/heads/nanopi6-v6.1.y/arch/arm64/boot/dts/rockchip/rk3576-nanopi5-common.dtsi
	wget -O "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/rk3576-nanopi5-mipi-lcd-yx70.dtsi \
		https://github.com/friendlyarm/kernel-rockchip/raw/refs/heads/nanopi6-v6.1.y/arch/arm64/boot/dts/rockchip/rk3576-nanopi5-mipi-lcd-yx70.dtsi
	wget -O "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/rk3576-nanopi5-csi0-imx415.dtsi \
		https://github.com/friendlyarm/kernel-rockchip/raw/refs/heads/nanopi6-v6.1.y/arch/arm64/boot/dts/rockchip/rk3576-nanopi5-csi0-imx415.dtsi
	wget -O "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/rk3576-nanopi5-csi1-imx415.dtsi \
		https://github.com/friendlyarm/kernel-rockchip/raw/refs/heads/nanopi6-v6.1.y/arch/arm64/boot/dts/rockchip/rk3576-nanopi5-csi1-imx415.dtsi
	echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3576-nanopi-m5.dtb' >> "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/Makefile

	# For ArmSoM Sige5
	wget -O "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/rk3576-armsom-sige5.dts \
		https://raw.githubusercontent.com/ArmSoM/rockchip-kernel/refs/heads/linux-6.1-stan-rkr6.1/arch/arm64/boot/dts/rockchip/rk3576-armsom-sige5.dts
	echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3576-armsom-sige5.dtb' >> "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/Makefile

	# For Luckfox Omni3576
	cp "$VENDOR_DTS"/omni3576/luckfox-*.dts* "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/
	sed -i 's/MIPI_DSI_MODE_EOT_PACKET/MIPI_DSI_MODE_NO_EOT_PACKET/' "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/luckfox-*.dts*
	mv "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/luckfox-omni3576.dts "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/rk3576-luckfox-omni3576.dts
	echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3576-luckfox-omni3576.dtb' >> "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/Makefile

	for f in "$PATCHES_DIR"/*.patch; do
		[ -f "$f" ] || continue
		echo "Applying patch: $f"
		patch -d "$LINUX_DIR" -p1 < "$f"
	done
fi

CONFIGS=$(realpath "$CONFIGS"/*)

for dtso in $(find "$VENDOR_DTS/bsp" -name \*.dtso); do
	[ -f "$dtso" ] || continue

	rel="${dtso##$VENDOR_DTS/bsp/}"
	subdir="${rel%/*}"
	[ "$subdir" = "$rel" ] && subdir=""

    dtsofile="${dtso##*/}"
	outfile="${subdir%/*}${subdir:+/}${dtsofile%.dtso}.dts"
	destdir="${LINUX_DIR}/arch/arm64/boot/dts/rockchip/overlay"
	destfile="${destdir}/${outfile}"

	[ -f "${destfile}" ] ||
		echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += overlay/${outfile%.dts}.dtbo" >> "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/Makefile

	install -pD -m 644 "${dtso}" "${destfile}"
done

pushd "$LINUX_DIR"
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) clean
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) defconfig rockchip_linux_defconfig
./scripts/kconfig/merge_config.sh -m .config $CONFIGS
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) olddefconfig
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) bindeb-pkg
popd

mkdir -p "$LINUX_OUT"
mv "$LINUX_DIR"/../linux-*.* "$LINUX_OUT"/
