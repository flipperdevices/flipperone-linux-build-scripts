#!/bin/bash
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${IMG_OUT:=out}"
: "${IMGSIZE:=4GiB}"}

set -e

TIMESTAMP=`date -u '+%Y%m%d-%H%M'`

: "${BUILD_ID:=$TIMESTAMP}"

mkdir -p "$IMG_OUT"

if [ ! -f "$IMG_OUT"/debian-rootfs.img.zst -o "$UPDATE_ROOTFS" ]; then
	./build-rootfs-img.sh
fi

TMPDIR=`mktemp -d`
cleanup() {
	rm -rf "$TMPDIR"
}
trap cleanup EXIT

bmaptool copy "$IMG_OUT"/debian-rootfs.img.zst "$IMG_OUT"/debian-rootfs.img
sync "$IMG_OUT"/debian-rootfs.img
TMP=`mktemp`
chmod 644 "$TMP"

debugfs -R "cat /boot/extlinux/extlinux.conf" "$IMG_OUT"/debian-rootfs.img | sed "/menu title/s/U-Boot menu/Flipper One $BUILD_ID/" > "$TMP"
debugfs -w -R "rm /boot/extlinux/extlinux.conf" "$IMG_OUT"/debian-rootfs.img
debugfs -w -R "write $TMP /boot/extlinux/extlinux.conf" "$IMG_OUT"/debian-rootfs.img

debugfs -R "cat /etc/default/u-boot" "$IMG_OUT"/debian-rootfs.img | sed "/U_BOOT_MENU_TITLE/s/U-Boot menu/Flipper One $BUILD_ID/" > "$TMP"
debugfs -w -R "rm /etc/default/u-boot" "$IMG_OUT"/debian-rootfs.img
debugfs -w -R "write $TMP /etc/default/u-boot" "$IMG_OUT"/debian-rootfs.img

debugfs -R "cat /usr/lib/os-release"  "$IMG_OUT"/debian-rootfs.img > "$TMP"
echo "BUILD_ID=$BUILD_ID" >> "$TMP"
debugfs -w -R "rm /usr/lib/os-release" "$IMG_OUT"/debian-rootfs.img
debugfs -w -R "write $TMP /usr/lib/os-release" "$IMG_OUT"/debian-rootfs.img
sync "$IMG_OUT"/debian-rootfs.img

rm -f "$TMP"

for s in 512 4096; do
	echo "Creating images for $s-byte sector size"
	truncate -s "$IMGSIZE" "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img
	sfdisk --sector-size $s "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img << EOF
label: gpt
first-lba: $((32768 / s))
start=32KiB, size=16352KiB, name=loader, type=3DE21764-95BD-54BD-A5C3-4ABE786F38A8
start=16MiB, size=+,        name=root,   type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, attrs="LegacyBIOSBootable"
EOF

	read START COUNT < <(
		sfdisk -d --sector-size $s "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img \
		| awk -F'[, =:]+' '/name="root"/ { print $3, $5 }'
	)
	start_bytes=$((START * s))
	count_bytes=$((COUNT * s))

	bmaptool subrange --dest-seek $start_bytes --length $count_bytes "$IMG_OUT"/debian-rootfs.img "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img

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

rm -rf "$TMPDIR" "$IMG_OUT"/debian-rootfs.img
