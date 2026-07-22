#!/bin/sh
# Composite NCM (USB Ethernet) + mass storage + MTP (/home). Thin preset over
# usb-gadget-setup.sh. MTP requires the umtprd daemon (see /etc/umtprd/umtprd.conf).
exec usb-gadget-setup.sh --name ncmmscmtp --pid 0xF12F --product "Flipper One Composite Device" --ncm --storage --mtp "$@"
