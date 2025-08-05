#!/bin/bash
: "${UBOOT_DIR:=prebuilt/u-boot}"
: "${OUT:=out}"

if [ -c /dev/kvm -a -w /dev/kvm ]; then
	DEBOS="debos"
else
	DEBOS="sudo debos"
fi

mkdir -p "$OUT"

$DEBOS --artifactdir="$OUT" debian-rk3576.yaml

for i in `basename -a "$UBOOT_DIR"/*`; do
	cp "$OUT"/debian-nobootloader.img "$OUT"/debian-"$i".img
	dd if="$UBOOT_DIR"/"$i"/u-boot-rockchip.bin of="$OUT"/debian-"$i".img seek=64 conv=notrunc
	bmaptool create -o "$OUT"/debian-"$i".img.bmap "$OUT"/debian-"$i".img
	pigz -f "$OUT"/debian-"$i".img
done

bmaptool create -o "$OUT"/debian-nobootloader.img.bmap "$OUT"/debian-nobootloader.img
pigz -f "$OUT"/debian-nobootloader.img
