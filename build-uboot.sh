#!/bin/bash
: "${BOARD:=all}"
: "${UBOOT_DIR:=src/u-boot}"
: "${TFA_DIR:=src/tfa}"
: "${TEE_DIR:=src/tee}"
: "${RKBIN_DIR:=src/rkbin}"
: "${KEEP_SRC:=no}"
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${CROSS_COMPILE64:=aarch64-linux-gnu-}"
: "${CROSS_COMPILE32:=arm-linux-gnueabihf-}"
: "${CONFIGS:=configs/u-boot}"

: "${UBOOT_GIT:=https://github.com/flipperdevices/u-boot.git}"
: "${UBOOT_BRANCH:=rk3576}"

: "${TFA_GIT:=https://github.com/ARM-software/arm-trusted-firmware.git}"
: "${TFA_BRANCH:=master}"

: "${TEE_GIT:=https://github.com/OP-TEE/optee_os.git}"
: "${TEE_BRANCH:=master}"

: "${RKBIN_GIT:=https://github.com/flipperdevices/rkbin}"
: "${RKBIN_BRANCH:=master}"

: "${USE_BL31:=opensource}"

set -e

for i in "$UBOOT_DIR" "$RKBIN_DIR" "$TFA_DIR" "$TEE_DIR"; do
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
[ ! -d "$TEE_DIR" ] && git clone --depth 1 -b "$TEE_BRANCH" "$TEE_GIT" "$TEE_DIR"

TEE=
pushd "$TEE_DIR"
make PLATFORM=rockchip-rk3576 CROSS_COMPILE32="$CROSS_COMPILE32" CROSS_COMPILE64="$CROSS_COMPILE64" -j$(nproc) clean
make PLATFORM=rockchip-rk3576 CROSS_COMPILE32="$CROSS_COMPILE32" CROSS_COMPILE64="$CROSS_COMPILE64" CFG_USER_TA_TARGETS=ta_arm64 -j$(nproc)
TEE=`realpath out/arm-plat-rockchip/core/tee.bin`
popd

CONFIGS=`realpath "$CONFIGS"/*`
ROCKCHIP_TPL=`realpath "$RKBIN_DIR"/bin/rk35/rk3576_ddr_*.bin | tail -n1`
BL31=

if [ x"$USE_BL31" = x"opensource" ]; then
	pushd "$TFA_DIR"
	make PLAT=rk3576 -j$(nproc) clean
	make PLAT=rk3576 BL32="$TEE" SPD=opteed -j$(nproc)
	popd
	BL31=`realpath "$TFA_DIR"/build/rk3576/release/bl31/bl31.elf`
else
	BL31=`realpath "$RKBIN_DIR"/bin/rk35/rk3576_bl31_v*.elf`
fi

pushd "$RKBIN_DIR"
rm -f rk3576_*loader_*.bin
./tools/boot_merger RKBOOT/RK3576MINIALL.ini
./tools/boot_merger RKBOOT/RK3576MINIALL_FSPI1.ini
popd

if [ x"$BOARD" = x"all" ]; then
	BOARDS=`basename -a -s "-rk3576_defconfig" "$UBOOT_DIR"/configs/*-rk3576_defconfig`
else
	BOARDS="$BOARD"
fi

NPROC=$(nproc)
NBOARDS=$(set -- $BOARDS; echo $#)

# Run as many boards in parallel as we have cores, but never more than
# the number of boards. Give each build an even slice of the cores
# (rounded up so we don't leave cores idle). Memory/IO assumed not to bind.
MAX_PAR=$(( NBOARDS < NPROC ? NBOARDS : NPROC ))
[ "$MAX_PAR" -lt 1 ] && MAX_PAR=1
JOBS=$(( (NPROC + MAX_PAR - 1) / MAX_PAR ))

# Track temp build dirs so we can clean them all up on exit.
TMPDIRS=""
cleanup() { [ -n "$TMPDIRS" ] && rm -rf $TMPDIRS; }
trap cleanup EXIT

build_board() {
	local i="$1"
	local out="$2"	# out-of-tree temp build dir

	make -C "$UBOOT_DIR" O="$out" -j"$JOBS" -l"$NPROC" \
		CROSS_COMPILE="$CROSS_COMPILE" \
		"$i"-rk3576_defconfig rockchip-ramboot.config || return 1
	"$UBOOT_DIR"/scripts/kconfig/merge_config.sh -m -O "$out" "$out/.config" "$CONFIGS" || return 1
	make -C "$UBOOT_DIR" O="$out" -j"$JOBS" -l"$NPROC" \
		CROSS_COMPILE="$CROSS_COMPILE" \
		BL31="$BL31" ROCKCHIP_TPL="$ROCKCHIP_TPL" TEE="$TEE" || return 1

	rm -rf "$UBOOT_OUT/$i"
	mkdir -p "$UBOOT_OUT/$i"
	cp "$out"/u-boot-rockchip*.bin "$UBOOT_OUT/$i"/
	cp "$RKBIN_DIR"/rk3576_*loader_*.bin "$UBOOT_OUT/$i"/
}

rc=0
for i in $BOARDS; do
	# Throttle: wait until fewer than MAX_PAR jobs are running.
	while [ "$(jobs -rp | wc -l)" -ge "$MAX_PAR" ]; do wait -n; done
	out=$(mktemp -d) || { rc=1; break; }
	TMPDIRS="$TMPDIRS $out"
	build_board "$i" "$out" &
done

# Collect results from all remaining jobs.
for pid in $(jobs -rp); do wait "$pid" || rc=1; done
exit "$rc"
