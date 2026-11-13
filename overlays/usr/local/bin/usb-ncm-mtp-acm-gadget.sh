#!/bin/sh
# Composite NCM (USB Ethernet) + MTP (/home) + USB serial (CDC-ACM). Thin preset over
# usb-gadget-setup.sh. MTP requires the umtprd daemon (see /etc/umtprd/umtprd.conf).
exec usb-gadget-setup.sh --name ncmmtpacm --pid 0xF12E --product "Flipper One Composite Device" --ncm --mtp --acm "$@"
