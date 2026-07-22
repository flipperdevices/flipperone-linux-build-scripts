#!/bin/sh
# Re-assert the USB gadget pullup after a Type-C cable connect. On this board dwc3 does not
# auto-reconnect on a replug: the Type-C side (fusb302/tcpm) detects the cable and sets
# orientation + usb-role, but the role never transitions (device-only port) and no VBUS/
# session reaches dwc3, so it never re-asserts the pullup. Toggling the UDC binding forces
# the host to re-enumerate. Kicked by udev on a Type-C partner attach.
set -e
udc=$(ls /sys/class/udc 2>/dev/null | head -n1)
[ -n "$udc" ] || exit 0
for u in /sys/kernel/config/usb_gadget/*/UDC; do
    [ -e "$u" ] || continue
    [ "$(cat "$u" 2>/dev/null)" = "$udc" ] || continue
    echo "" > "$u"
    echo "$udc" > "$u"
    exit 0
done
