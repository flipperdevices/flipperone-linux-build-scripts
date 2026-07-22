#!/bin/sh
# CDC-NCM (USB Ethernet) gadget. Thin preset over usb-gadget-setup.sh.
exec usb-gadget-setup.sh --name ncmg --pid 0xF121 --product "Flipper One USB Ethernet" --ncm "$@"
