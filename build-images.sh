#!/bin/bash
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${LINUX_OUT:=prebuilt/linux}"
: "${IMG_OUT:=out}"

TIMESTAMP=`date -u '+%Y%m%d-%H%M'`

if [ -c /dev/kvm -a -w /dev/kvm ]; then
	DEBOS="debos"
else
	DEBOS="sudo debos"
fi

mkdir -p "$IMG_OUT"

$DEBOS --artifactdir="$IMG_OUT" -t timestamp:"$TIMESTAMP" -t kerneldir:"$LINUX_OUT" debian-rk3576.yaml

for i in `basename -a "$UBOOT_OUT"/*`; do
	cp "$IMG_OUT"/debian-nobootloader-"$TIMESTAMP".img "$IMG_OUT"/debian-"$i"-"$TIMESTAMP".img
	dd if="$UBOOT_OUT"/"$i"/u-boot-rockchip.bin of="$IMG_OUT"/debian-"$i"-"$TIMESTAMP".img seek=64 conv=notrunc
	bmaptool create -o "$IMG_OUT"/debian-"$i"-"$TIMESTAMP".img.bmap "$IMG_OUT"/debian-"$i"-"$TIMESTAMP".img
	pigz -f "$IMG_OUT"/debian-"$i"-"$TIMESTAMP".img
done

bmaptool create -o "$IMG_OUT"/debian-nobootloader-"$TIMESTAMP".img.bmap "$IMG_OUT"/debian-nobootloader-"$TIMESTAMP".img
pigz -f "$IMG_OUT"/debian-nobootloader-"$TIMESTAMP".img
