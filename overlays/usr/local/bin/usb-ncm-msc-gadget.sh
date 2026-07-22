#!/bin/sh
# Composite NCM (USB Ethernet) + mass storage. Thin preset over usb-gadget-setup.sh.
exec usb-gadget-setup.sh --name ncmmsc --pid 0xF12F --product "Flipper One Composite Device" --ncm --storage "$@"
