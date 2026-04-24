#!/bin/bash
: "${LINUX_OUT:=prebuilt/linux}"
: "${IMG_OUT:=out}"
: "${IMGSIZE:=5GiB}"}

set -e

if [ -c /dev/kvm -a -w /dev/kvm ]; then
	echo "Have virtualization support, can use fakemachine (default, fast, safe)"
	DEBOS="debos -c $(nproc) -m 6Gb"
elif [ -f /.dockerenv ]; then
	echo "Running in a container without access to virtualization, fall back to the slow method"
	DEBOS="debos -b qemu -c $(nproc) -m 6Gb"
elif [ `id -u` -eq 0 ]; then
	echo "Running as root, can use the host mode without fakemachine (fast, less safe)"
	DEBOS="debos"
else
	echo "else"
	DEBOS="sudo debos --disable-fakemachine"
fi

mkdir -p "$IMG_OUT"

if [ ! -f "$IMG_OUT"/debian-ospack.tar.gz -o "$UPDATE_OSPACK" ]; then
	./build-ospack.sh
fi


STAGE_IMG="$IMG_OUT/stage.ext4"
STAGE_DIR=".stage"
STAGE_MNT="$PWD/$STAGE_DIR"
	
truncate -s 20G "$STAGE_IMG"
mkfs.ext4 -F "$STAGE_IMG"

mkdir -p "$STAGE_MNT"
LOOP=$(losetup -f --show "$STAGE_IMG")
mount "$LOOP" "$STAGE_MNT"

mkdir -p "$STAGE_MNT"/linux_tmp
cp -r "$LINUX_OUT"/* "$STAGE_MNT"/linux_tmp
cp "$IMG_OUT"/debian-ospack.tar.gz "$STAGE_MNT"

echo "Creating the root FS image"
$DEBOS --artifactdir="$STAGE_MNT" -t imagesize:"$IMGSIZE" -t kerneldir:"$STAGE_DIR"/linux_tmp debian-rk3576-img.yaml

sync "$STAGE_MNT"/debian-nobootloader.img

owner=$(stat -c %u "$STAGE_MNT"/debian-nobootloader.img)
whoami=$(id -u)
if [ "$owner" -ne "$whoami" ]; then
	sudo chown "$whoami" "$STAGE_MNT"/debian-nobootloader.img
fi

read START COUNT < <(
	parted -s -m "$STAGE_MNT"/debian-nobootloader.img unit s print \
	| awk -F: -v p="2" '$1==p { gsub(/s/,"",$2); gsub(/s/,"",$4); print $2, $4 }'
)

start_bytes=$((START * 512))
count_bytes=$((COUNT * 512))
end_bytes=$((start_bytes + count_bytes))
img_size_bytes=$(stat -c %s "$STAGE_MNT"/debian-nobootloader.img)
tail_bytes=$((img_size_bytes - end_bytes))

if [ "$tail_bytes" -gt 0 ]; then
	truncate -c -s "$end_bytes" "$STAGE_MNT"/debian-nobootloader.img
fi

if [ "$start_bytes" -gt 0 ]; then
	cd "$STAGE_MNT"
	fallocate --collapse-range -o 0 -l "$start_bytes" debian-nobootloader.img	
fi

sync "$STAGE_MNT"/debian-nobootloader.img
bmaptool create -o "$STAGE_MNT"/debian-rootfs.img.bmap "$STAGE_MNT"/debian-nobootloader.img
zeekstd -f -o "$STAGE_MNT"/debian-rootfs.img.zst "$STAGE_MNT"/debian-nobootloader.img

rm -rf "$STAGE_MNT"/linux_tmp "$STAGE_MNT"/debian-nobootloader.img

cp -r $STAGE_MNT/* $IMG_OUT/

cd "$IMG_OUT"
umount "$LOOP"
losetup -d "$LOOP"
rm -f "$STAGE_IMG"
