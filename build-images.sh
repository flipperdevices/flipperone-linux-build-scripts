#!/bin/bash
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${LINUX_OUT:=prebuilt/linux}"
: "${IMG_OUT:=out}"

set -e

TIMESTAMP=`date -u '+%Y%m%d-%H%M'`

: "${BUILD_ID:=$TIMESTAMP}"

if [ -c /dev/kvm -a -w /dev/kvm ]; then
	# Have virtualization support, can use fakemachine (default, fast, safe)
	DEBOS="debos -c $(nproc) -m 6Gb"
elif [ -f /.dockerenv ]; then
	# Running in a container without access to virtualization, fall back to the slow method
	DEBOS="debos -b qemu -c $(nproc) -m 6Gb"
elif [ `id -u` -eq 0 ]; then
	# Running as root, can use the host mode without fakemachine (fast, less safe)
	DEBOS="debos"
else
	DEBOS="sudo debos"
fi

mkdir -p "$IMG_OUT"

if [ ! -f "$IMG_OUT"/debian-ospack.tar.gz -o "$UPDATE_OSPACK" ]; then
	./build-ospack.sh
fi

rm -rf prebuilt/linux_tmp
mkdir -p prebuilt/linux_tmp

cp -r "$LINUX_OUT"/* prebuilt/linux_tmp/
TMPDIR=`mktemp -d`
cp -f "$IMG_OUT"/debian-ospack.tar.gz "$TMPDIR"

for s in 512 4096; do
	echo "Creating images for $s-byte sector size"
	$DEBOS --artifactdir="$TMPDIR" -t buildid:"$BUILD_ID" -t kerneldir:prebuilt/linux_tmp -t sectorsize:"$s" debian-rk3576-img.yaml

	for i in `basename -a "$UBOOT_OUT"/*`; do
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
	done

	echo "nobootloader image:"
	echo " - Creating a block map"
	bmaptool create -o "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img.bmap "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img
	echo " - Compressing the final image"
	pigz -c "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img > "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img.gz
	rm -f "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img
done

rm -rf "$TMPDIR"
