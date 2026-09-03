#!/bin/bash
: "${UBOOT_OUT:=prebuilt/u-boot}"
: "${IMG_OUT:=out}"
: "${IMGSIZE:=6GiB}"

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

# Boot entries are pure BLS in /boot/loader/entries, read directly by U-Boot's
# 'bls' bootmeth (no extlinux.conf). Nothing to rewrite here for the boot menu.

NPROC=$(nproc)
BOARDS=`basename -a "$UBOOT_OUT"/*`
NJOBS=$(( $(set -- $BOARDS; echo $#) + 1 ))	# the boards, plus the nobootloader image

compress_image() {
	local i="$1"
	local img="$2"

	echo "$i: creating a block map"
	bmaptool create -o "$IMG_OUT"/debian-"$s"-"$i"-"$BUILD_ID".img.bmap "$img" || return 1
	echo "$i: compressing the final image"
	pigz -p "$PIGZ_THREADS" -c "$img" > "$IMG_OUT"/debian-"$s"-"$i"-"$BUILD_ID".img.gz || return 1
}

build_board_image() {
	local i="$1"
	local img="$TMPDIR"/debian-"$s"-"$i"-"$BUILD_ID".img

	echo "$i: copying the base image"
	cp "$base" "$img" || return 1
	echo "$i: adding a board-specific bootloader"
	dd if="$UBOOT_OUT"/"$i"/u-boot-rockchip.bin of="$img" seek=64 conv=notrunc status=none || return 1
	compress_image "$i" "$img" || return 1
	rm -f "$img"
}

for s in 512 4096; do
	echo "Creating images for $s-byte sector size"
	truncate -s "$IMGSIZE" "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img
	sfdisk --sector-size $s "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img << EOF
label: gpt
first-lba: $((32768 / s))
start=32KiB, size=61408KiB, name=loader,   type=3DE21764-95BD-54BD-A5C3-4ABE786F38A8
start=60MiB, size=4MiB,     name=metadata, type=8DA63339-0007-60C0-C436-083AC8230908
start=64MiB, size=+,        name=root,     type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, attrs="LegacyBIOSBootable"
EOF

	read START COUNT < <(
		sfdisk -d --sector-size $s "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img \
		| awk -F'[, =:]+' '/name="root"/ { print $3, $5 }'
	)
	start_bytes=$((START * s))
	count_bytes=$((COUNT * s))

	bmaptool subrange --dest-seek $start_bytes --length $count_bytes "$IMG_OUT"/debian-rootfs.img "$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img

	base="$TMPDIR"/debian-"$s"-nobootloader-"$BUILD_ID".img

	# Every parallel job needs one more copy of the base image. cp keeps the
	# holes, so the real cost is what the base occupies, not its apparent
	# size. Leave a tenth of the free space as slack.
	IMG_COST=$(du -s --block-size=1 -- "$base" | cut -f1)
	[ "$IMG_COST" -lt 1 ] && IMG_COST=1
	AVAIL=$(df -B1 --output=avail -- "$TMPDIR" | tail -n1)
	SPACE_JOBS=$(( AVAIL * 9 / 10 / IMG_COST ))

	# Run as many jobs at once as both the free space and the cores allow,
	# and give each one an even slice of the cores for pigz (rounded up so we
	# don't leave cores idle).
	MAX_PAR=$(( NJOBS < NPROC ? NJOBS : NPROC ))
	[ "$SPACE_JOBS" -lt "$MAX_PAR" ] && MAX_PAR=$SPACE_JOBS
	[ "$MAX_PAR" -lt 1 ] && MAX_PAR=1
	PIGZ_THREADS=$(( (NPROC + MAX_PAR - 1) / MAX_PAR ))

	echo " - $IMG_COST bytes per image, $AVAIL free: room for $SPACE_JOBS"
	echo " - Building $NJOBS images, $MAX_PAR at a time, $PIGZ_THREADS pigz threads each"

	# The base is only read from here on, so it can compress alongside the
	# boards -- it just has to outlive them. Dispatch it first, since its
	# pigz pass is the longest single job, and it needs no extra space.
	{ compress_image nobootloader "$base" || echo nobootloader >> "$TMPDIR"/failed-"$s"; } &

	for i in $BOARDS; do
		# Throttle: wait until fewer than MAX_PAR jobs are running.
		while [ "$(jobs -rp | wc -l)" -ge "$MAX_PAR" ]; do wait -n || true; done
		{ build_board_image "$i" || echo "$i" >> "$TMPDIR"/failed-"$s"; } &
	done

	wait

	rm -f "$base"

	if [ -s "$TMPDIR"/failed-"$s" ]; then
		echo "Failed to build $s-byte images for:" \
			$(tr '\n' ' ' < "$TMPDIR"/failed-"$s") >&2
		exit 1
	fi
done

rm -rf "$TMPDIR" "$IMG_OUT"/debian-rootfs.img
