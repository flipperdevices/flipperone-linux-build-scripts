#!/bin/bash
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${IMG_OUT:=out}"
: "${IMGSIZE:=5GiB}"}

set -e

TIMESTAMP=`date -u '+%Y%m%d-%H%M'`

: "${BUILD_ID:=$TIMESTAMP}"

mkdir -p "$IMG_OUT"

if [ ! -f "$IMG_OUT"/debian-rootfs.img.zst -o "$UPDATE_ROOTFS" ]; then
	./build-rootfs-img.sh
fi

TMPDIR=`mktemp -d`

for s in 512 4096; do
	echo "Creating images for $s-byte sector size"
	truncate -s "$IMGSIZE" "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img

	if [ -c /dev/kvm ] && [ -w /dev/kvm ]; then
    	FM_BACKEND="kvm"
	else
    	FM_BACKEND="qemu"
	fi

	echo "Using fakemachine backend: $FM_BACKEND"
	
	cp -f partitions-script.sh "$IMG_OUT"/partitions-script.sh
	fakemachine \
	    -b "$FM_BACKEND" \
    	-S "$s" \
    	-i "$TMPDIR/debian-$s-nobootloader-$BUILD_ID.img" \
    	-e IMG:/artifacts/debian-rootfs.img.zst \
    	-e DISK:/dev/disk/by-fakemachine-label/fakedisk-0 \
    	-e PART:/dev/disk/by-fakemachine-label/fakedisk-0-part2 \
    	-e BUILD_ID:"$BUILD_ID" \
    	-v "$IMG_OUT":/artifacts \
    	-- /artifacts/partitions-script.sh
	rm -f "$IMG_OUT"/partitions-script.sh

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
	bmaptool create -o "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img.bmap "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img
	echo " - Compressing the final image"
	pigz -c "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img > "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img.gz
	rm -f "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img
done

rm -rf "$TMPDIR"
