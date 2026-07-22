#!/bin/sh
# Mass-storage gadget, shares the UFS by default. Thin preset over usb-gadget-setup.sh.
# A later --sdcard / --iso / medium option overrides the default --sda.
exec usb-gadget-setup.sh --name mscg --pid 0xF122 --product "Flipper One USB Storage" --storage --sda "$@"
