#!/bin/bash
: "${LINUX_OUT:=prebuilt/linux}"
: "${IMG_OUT:=out}"
: "${IMGSIZE:=6GiB}"

set -e

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
	DEBOS="sudo debos --disable-fakemachine"
fi

mkdir -p "$IMG_OUT"

if [ ! -f "$IMG_OUT"/debian-ospack.tar.gz -o "$UPDATE_OSPACK" ]; then
	./build-ospack.sh
fi

rm -rf "$IMG_OUT"/linux_tmp
mkdir -p "$IMG_OUT"/linux_tmp
cp -r "$LINUX_OUT"/* "$IMG_OUT"/linux_tmp

echo "Creating the root FS image"
$DEBOS --artifactdir="$IMG_OUT" -t imagesize:"$IMGSIZE" -t kerneldir:linux_tmp debian-rk3576-img.yaml
sync "$IMG_OUT"/debian-nobootloader.img

owner=$(stat -c %u "$IMG_OUT"/debian-nobootloader.img)
whoami=$(id -u)
if [ "$owner" -ne "$whoami" ]; then
	sudo chown "$whoami" "$IMG_OUT"/debian-nobootloader.img
fi

read START COUNT < <(
	sfdisk -d "$IMG_OUT"/debian-nobootloader.img \
	| awk -F'[, =:]+' '/name="root"/ { print $3, $5 }'
)
start_bytes=$((START * 512))
count_bytes=$((COUNT * 512))
bmaptool subrange --start $start_bytes --length $count_bytes "$IMG_OUT"/debian-nobootloader.img "$IMG_OUT"/debian-rootfs.img
bmaptool create -o "$IMG_OUT"/debian-rootfs.img.bmap "$IMG_OUT"/debian-rootfs.img
zeekstd -f -o "$IMG_OUT"/debian-rootfs.img.zst "$IMG_OUT"/debian-rootfs.img

rm -rf "$IMG_OUT"/linux_tmp "$IMG_OUT"/debian-nobootloader.img "$IMG_OUT"/debian-rootfs.img
