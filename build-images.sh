#!/bin/bash
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${LINUX_OUT:=prebuilt/linux}"
: "${IMG_OUT:=out}"

set -e

TIMESTAMP=`date -u '+%Y%m%d-%H%M'`

: "${BUILD_ID:=$TIMESTAMP}"

# Capture Git information
[ -n "${GIT_HASH}" ] || GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
[ -n "${GIT_BRANCH}" ] || GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || echo "detached")
[ -n "${GIT_MSG}" ] || GIT_MSG=$(git log -1 --pretty=format:"%s" 2>/dev/null || echo "unknown")
[ -n "${GIT_INFO}" ] || GIT_INFO="${GIT_BRANCH}@${GIT_HASH}: ${GIT_MSG}"

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
rm -rf prebuilt/linux_tmp
mkdir -p prebuilt/linux_tmp
cp "$LINUX_OUT"/* prebuilt/linux_tmp/

$DEBOS --artifactdir="$IMG_OUT" -t buildid:"$BUILD_ID" -t gitinfo:"$GIT_INFO" -t kerneldir:prebuilt/linux_tmp debian-rk3576-ospack.yaml
rm -rf prebuilt/linux_tmp

for s in 512 4096; do
echo "Creating images for $s-byte sector size"
$DEBOS --artifactdir="$IMG_OUT" -t buildid:"$BUILD_ID" -t sectorsize:"$s" debian-rk3576-img.yaml

for i in `basename -a "$UBOOT_OUT"/*`; do
	echo "$i board:"
	cp "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img "$IMG_OUT"/debian-"$s"-"$i"-"$BUILD_ID".img
	dd if="$UBOOT_OUT"/"$i"/u-boot-rockchip.bin of="$IMG_OUT"/debian-"$s"-"$i"-"$BUILD_ID".img seek=64 conv=notrunc
	bmaptool create -o "$IMG_OUT"/debian-"$s"-"$i"-"$BUILD_ID".img.bmap "$IMG_OUT"/debian-"$s"-"$i"-"$BUILD_ID".img
	pigz -f "$IMG_OUT"/debian-"$s"-"$i"-"$BUILD_ID".img
done

bmaptool create -o "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img.bmap "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img
pigz -f "$IMG_OUT"/debian-"$s"-nobootloader-"$BUILD_ID".img
done
