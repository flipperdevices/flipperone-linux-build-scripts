#!/bin/sh
# USB serial (CDC-ACM) gadget. Thin preset over usb-gadget-setup.sh.
exec usb-gadget-setup.sh --name acmg --pid 0xF123 --product "Flipper One USB Serial" --acm "$@"
