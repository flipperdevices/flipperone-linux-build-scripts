#!/bin/bash
set -e
parted -s "$DISK" \
        mklabel gpt \
        mkpart primary 32KiB 16MiB \
        name 1 loader \
        mkpart primary ext4 16MiB 100% \
        name 2 root \
        set 2 boot on
bmaptool -q copy "$IMG" "$PART"
TMP=`mktemp`
chmod 644 "$TMP"

debugfs -R "cat /boot/extlinux/extlinux.conf" "$PART" | sed "/menu title/s/U-Boot menu/Flipper build $BUILD_ID/" > "$TMP"
debugfs -w -R "rm /boot/extlinux/extlinux.conf" "$PART"
debugfs -w -R "write $TMP /boot/extlinux/extlinux.conf" "$PART"

debugfs -R "cat /etc/default/u-boot" "$PART" | sed "/U_BOOT_MENU_TITLE/s/U-Boot menu/Flipper build $BUILD_ID/" > "$TMP"
debugfs -w -R "rm /etc/default/u-boot" "$PART"
debugfs -w -R "write $TMP /etc/default/u-boot" "$PART"

debugfs -R "cat /usr/lib/os-release"  "$PART"> "$TMP"
echo "BUILD_ID=$BUILD_ID" >> "$TMP"
debugfs -w -R "rm /usr/lib/os-release" "$PART"
debugfs -w -R "write $TMP /usr/lib/os-release" "$PART"

rm -f "$TMP"
sync "$DISK"
