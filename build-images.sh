#!/bin/bash
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${LINUX_OUT:=prebuilt/linux}"
: "${IMG_OUT:=out}"

TIMESTAMP=`date -u '+%Y%m%d-%H%M'`

if [ -c /dev/kvm -a -w /dev/kvm ]; then
	# Have virtualization support, can use fakemachine (default, fast, safe)
	DEBOS="debos"
elif [ -f /.dockerenv ]; then
	# Running in a container without access to virtualization, fall back to the slow method
	DEBOS="debos -b qemu -c $(nproc)"
elif [ `id -u` -eq 0 ]; then
	# Running as root, can use the host mode without fakemachine (fast, less safe)
	DEBOS="debos"
else
	DEBOS="sudo debos"
fi

mkdir -p "$IMG_OUT"
rm -rf prebuilt/linux_tmp
mkdir -p prebuilt/linux_tmp
cp "$LINUX_OUT"/* prebuilt/linux_tmp/

$DEBOS --artifactdir="$IMG_OUT" -t timestamp:"$TIMESTAMP" -t kerneldir:prebuilt/linux_tmp debian-rk3576.yaml

[ $? -ne 0 ] && echo "debos didn't run successfully, aborting" && exit 1

rm -rf prebuilt/linux_tmp

for i in `basename -a "$UBOOT_OUT"/*`; do
	cp "$IMG_OUT"/debian-nobootloader-"$TIMESTAMP".img "$IMG_OUT"/debian-"$i"-"$TIMESTAMP".img
	dd if="$UBOOT_OUT"/"$i"/u-boot-rockchip.bin of="$IMG_OUT"/debian-"$i"-"$TIMESTAMP".img seek=64 conv=notrunc
	bmaptool create -o "$IMG_OUT"/debian-"$i"-"$TIMESTAMP".img.bmap "$IMG_OUT"/debian-"$i"-"$TIMESTAMP".img
	pigz -f "$IMG_OUT"/debian-"$i"-"$TIMESTAMP".img
done

bmaptool create -o "$IMG_OUT"/debian-nobootloader-"$TIMESTAMP".img.bmap "$IMG_OUT"/debian-nobootloader-"$TIMESTAMP".img
pigz -f "$IMG_OUT"/debian-nobootloader-"$TIMESTAMP".img
