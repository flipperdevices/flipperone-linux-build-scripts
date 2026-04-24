#!/bin/bash
: "${LINUX_OUT:=prebuilt/linux}"
: "${IMG_OUT:=out}"
: "${IMGSIZE:=4GiB}"}

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
$DEBOS --artifactdir="$IMG_OUT" -t imagesize:"$IMGSIZE" -t kerneldir:"$IMG_OUT"/linux_tmp debian-rk3576-img.yaml
sync "$IMG_OUT"/debian-nobootloader.img

owner=$(stat -c %u "$IMG_OUT"/debian-nobootloader.img)
whoami=$(id -u)
if [ "$owner" -ne "$whoami" ]; then
	sudo chown "$whoami" "$IMG_OUT"/debian-nobootloader.img
fi

read START COUNT < <(
	parted -s -m "$IMG_OUT"/debian-nobootloader.img unit s print \
	| awk -F: -v p="2" '$1==p { gsub(/s/,"",$2); gsub(/s/,"",$4); print $2, $4 }'
)
start_bytes=$((START * 512))
count_bytes=$((COUNT * 512))
end_bytes=$((start_bytes + count_bytes))
img_size_bytes=$(stat -c %s "$IMG_OUT"/debian-nobootloader.img)
tail_bytes=$((img_size_bytes - end_bytes))
if [ "$tail_bytes" -gt 0 ]; then
	truncate -c -s "$end_bytes" "$IMG_OUT"/debian-nobootloader.img
fi
if [ "$start_bytes" -gt 0 ]; then
	fallocate --collapse-range -o 0 -l "$start_bytes" "$IMG_OUT"/debian-nobootloader.img
fi
sync "$IMG_OUT"/debian-nobootloader.img
bmaptool create -o "$IMG_OUT"/debian-rootfs.img.bmap "$IMG_OUT"/debian-nobootloader.img
zeekstd -f -o "$IMG_OUT"/debian-rootfs.img.zst "$IMG_OUT"/debian-nobootloader.img

rm -rf "$IMG_OUT"/linux_tmp "$IMG_OUT"/debian-nobootloader.img
