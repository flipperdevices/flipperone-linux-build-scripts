#!/bin/bash
: "${LINUX_DIR:=src/linux}"
: "${VENDOR_DTS:=vendor-dts}"
: "${KEEP_SRC:=no}"
: "${LINUX_OUT:=prebuilt/linux}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${BASE_CONFIG:=configs/minconfig-mainline}"
: "${CONFIGS:=configs/linux}"

# Use the Github mirror by default, as it has beefier infrastructure vs. kernel.org
: "${LINUX_GIT:=https://github.com/torvalds/linux.git}"
: "${LINUX_BRANCH:=master}"

set -e

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

for dtso in $(find "$VENDOR_DTS/mainline" -name \*.dtso); do
	[ -f "$dtso" ] || continue

	rel="${dtso##$VENDOR_DTS/mainline/}"
	subdir="${rel%/*}"
	[ "$subdir" = "$rel" ] && subdir=""

    dtsofile="${dtso##*/}"
	outfile="${subdir%/*}${subdir:+/}${dtsofile}"
	destdir="${LINUX_DIR}/arch/arm64/boot/dts/rockchip/overlay"
	destfile="${destdir}/${outfile}"

	[ -f "${destfile}" ] ||
		echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += overlay/${outfile%.dtso}.dtbo" >> "$LINUX_DIR"/arch/arm64/boot/dts/rockchip/Makefile

	install -pD -m 644 "${dtso}" "${destfile}"
done

pushd "$LINUX_DIR"
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) clean
./scripts/kconfig/merge_config.sh -m "$BASE_CONFIG" "$CONFIGS"
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) olddefconfig
make ARCH=arm64 DTC_FLAGS="-@" CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) bindeb-pkg
popd

mkdir -p "$LINUX_OUT"
mv "$LINUX_DIR"/../linux-*.* "$LINUX_OUT"/
