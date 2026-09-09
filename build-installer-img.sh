#!/bin/bash
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${LINUX_OUT:=prebuilt/linux}"
: "${IMG_OUT:=out}"
: "${BOOTSIZE:=128MiB}"
: "${IMGSIZE:=145MiB}"
: "${INSTALLER_BOOTARGS:=console=ttyS0,1500000n8 fbcon=map:1}"

set -e

TIMESTAMP=`date -u '+%Y%m%d-%H%M'`

: "${BUILD_ID:=$TIMESTAMP}"

KERNEL_FILES="$LINUX_OUT"/linux-mainline-files
DTBS="$KERNEL_FILES"/dtbs/rockchip

if [ ! -f "$INSTALLER_INITRD" ]; then
	echo "INSTALLER_INITRD must point at the installer initrd (rootfs.cpio.gz)," \
		"the same artifact build-uboot.sh takes. Build one with" \
		"https://github.com/flipperdevices/flipperos-installer-initramfs" >&2
	exit 1
fi

if [ ! -f "$KERNEL_FILES"/vmlinuz ]; then
	echo "No kernel at $KERNEL_FILES/vmlinuz -- run ./build-kernel-mainline.sh first" >&2
	exit 1
fi

if ! compgen -G "$DTBS"/'rk3576-*.dtb' > /dev/null; then
	echo "No rk3576 device trees in $DTBS" >&2
	exit 1
fi

mkdir -p "$IMG_OUT"

TMPDIR=`mktemp -d`
cleanup() {
	rm -rf "$TMPDIR"
}
trap cleanup EXIT

# The boot filesystem is identical on every board: U-Boot's extlinux bootmeth
# expands 'fdtdir' with $fdtfile, which every board's defconfig sets to
# rockchip/rk3576-<board>.dtb, so one config picks the right DT everywhere.
echo "Creating the boot filesystem"
cat > "$TMPDIR"/extlinux.conf << EOF
menu title FlipperOS installer $BUILD_ID
timeout 30
default installer

label FlipperOS-installer
	menu label FlipperOS installer
	kernel /vmlinuz
	initrd /rootfs.cpio.gz
	fdtdir /dtbs
	append $INSTALLER_BOOTARGS
EOF

# mtools rather than a loop mount, so this needs no privileges.
truncate -s "$BOOTSIZE" "$TMPDIR"/boot.img
mkfs.vfat -F 32 -n INSTALLER "$TMPDIR"/boot.img > /dev/null
mmd -i "$TMPDIR"/boot.img ::/extlinux ::/dtbs ::/dtbs/rockchip
mcopy -i "$TMPDIR"/boot.img "$TMPDIR"/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i "$TMPDIR"/boot.img "$KERNEL_FILES"/vmlinuz ::/vmlinuz
mcopy -i "$TMPDIR"/boot.img "$INSTALLER_INITRD" ::/rootfs.cpio.gz
mcopy -i "$TMPDIR"/boot.img "$DTBS"/rk3576-*.dtb ::/dtbs/rockchip/
if compgen -G "$DTBS"/'rk3576-*.dtbo' > /dev/null; then
	mcopy -i "$TMPDIR"/boot.img "$DTBS"/rk3576-*.dtbo ::/dtbs/rockchip/
fi

NPROC=$(nproc)
BOARDS=`basename -a "$UBOOT_OUT"/*`
NJOBS=$(set -- $BOARDS; echo $#)

# Every image is ~145MiB, so there is no point budgeting disk space the way
# build-images.sh has to; the cores are the only limit.
MAX_PAR=$(( NJOBS < NPROC ? NJOBS : NPROC ))
[ "$MAX_PAR" -lt 1 ] && MAX_PAR=1
PIGZ_THREADS=$(( (NPROC + MAX_PAR - 1) / MAX_PAR ))

base="$TMPDIR"/installer-base-"$BUILD_ID".img

echo "Creating the base image"
truncate -s "$IMGSIZE" "$base"
sfdisk --sector-size 512 "$base" << EOF
label: gpt
first-lba: 64
start=32KiB, size=16352KiB, name=loader, type=3DE21764-95BD-54BD-A5C3-4ABE786F38A8
start=16MiB, size=$BOOTSIZE, name=boot,  type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
EOF

read BOOT_START BOOT_COUNT < <(
	sfdisk -d --sector-size 512 "$base" \
	| awk -F'[, =:]+' '/name="boot"/ { print $3, $5 }'
)
read LOADER_START LOADER_COUNT < <(
	sfdisk -d --sector-size 512 "$base" \
	| awk -F'[, =:]+' '/name="loader"/ { print $3, $5 }'
)
LOADER_BYTES=$((LOADER_COUNT * 512))

dd if="$TMPDIR"/boot.img of="$base" bs=512 seek=$BOOT_START conv=notrunc status=none

build_board_image() {
	local i="$1"
	local img="$TMPDIR"/installer-"$i"-"$BUILD_ID".img
	local uboot="$UBOOT_OUT"/"$i"/u-boot-rockchip.bin

	# The loader partition is much tighter here than in build-images.sh, so
	# check before dd runs over the start of the boot filesystem.
	local size=$(stat -c %s -- "$uboot") || return 1
	if [ "$size" -gt "$LOADER_BYTES" ]; then
		echo "$i: $uboot is $size bytes, loader partition holds $LOADER_BYTES" >&2
		return 1
	fi

	echo "$i: copying the base image"
	cp "$base" "$img" || return 1
	echo "$i: adding a board-specific bootloader"
	dd if="$uboot" of="$img" seek=$LOADER_START conv=notrunc status=none || return 1
	echo "$i: creating a block map"
	bmaptool create -o "$IMG_OUT"/installer-"$i"-"$BUILD_ID".img.bmap "$img" || return 1
	echo "$i: compressing the final image"
	pigz -p "$PIGZ_THREADS" -c "$img" > "$IMG_OUT"/installer-"$i"-"$BUILD_ID".img.gz || return 1
	rm -f "$img"
}

echo "Building $NJOBS images, $MAX_PAR at a time, $PIGZ_THREADS pigz threads each"

for i in $BOARDS; do
	# Throttle: wait until fewer than MAX_PAR jobs are running.
	while [ "$(jobs -rp | wc -l)" -ge "$MAX_PAR" ]; do wait -n || true; done
	{ build_board_image "$i" || echo "$i" >> "$TMPDIR"/failed; } &
done

wait

if [ -s "$TMPDIR"/failed ]; then
	echo "Failed to build installer images for:" \
		$(tr '\n' ' ' < "$TMPDIR"/failed) >&2
	exit 1
fi
