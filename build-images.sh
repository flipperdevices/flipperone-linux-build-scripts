#!/bin/bash
: "${UBOOT_DIR:=prebuilt/u-boot}"
: "${OUT:=out}"

TIMESTAMP=`date -u '+%Y%m%d-%H%M'`

if [ -c /dev/kvm -a -w /dev/kvm ]; then
	DEBOS="debos"
else
	DEBOS="sudo debos"
fi

mkdir -p "$OUT"

$DEBOS --artifactdir="$OUT" -t timestamp:"$TIMESTAMP" debian-rk3576.yaml

for i in `basename -a "$UBOOT_DIR"/*`; do
	cp "$OUT"/debian-nobootloader-"$TIMESTAMP".img "$OUT"/debian-"$i"-"$TIMESTAMP".img
	dd if="$UBOOT_DIR"/"$i"/u-boot-rockchip.bin of="$OUT"/debian-"$i"-"$TIMESTAMP".img seek=64 conv=notrunc
	bmaptool create -o "$OUT"/debian-"$i"-"$TIMESTAMP".img.bmap "$OUT"/debian-"$i"-"$TIMESTAMP".img
	pigz -f "$OUT"/debian-"$i"-"$TIMESTAMP".img
done

bmaptool create -o "$OUT"/debian-nobootloader-"$TIMESTAMP".img.bmap "$OUT"/debian-nobootloader-"$TIMESTAMP".img
pigz -f "$OUT"/debian-nobootloader-"$TIMESTAMP".img
