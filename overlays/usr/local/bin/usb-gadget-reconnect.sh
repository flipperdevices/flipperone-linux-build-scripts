#!/bin/sh
# Re-assert the USB gadget pullup after a Type-C cable connect. On this board dwc3 does not
# auto-reconnect on a replug: the Type-C side (fusb302/tcpm) detects the cable and sets
# orientation + usb-role, but the role never transitions (device-only port) and no VBUS/
# session reaches dwc3, so it never re-asserts the pullup. Kicked by udev on a Type-C partner
# attach, it acts only when the host has not come back by itself. Toggling the UDC binding
# forces the host to re-enumerate. MTP does not survive that, it left the gadget unbound, so
# a gadget with MTP has its unit restarted instead, queued behind a start still in progress.
set -e
udc=$(ls /sys/class/udc 2>/dev/null | head -n1)
[ -n "$udc" ] || exit 0
for _ in 1 2 3 4 5 6; do
    [ "$(cat "/sys/class/udc/$udc/state" 2>/dev/null)" = "not attached" ] || exit 0
    sleep 0.5
done
for u in /sys/kernel/config/usb_gadget/*/UDC; do
    [ -e "$u" ] || continue
    [ "$(cat "$u" 2>/dev/null)" = "$udc" ] || continue
    for f in "${u%/UDC}"/functions/ffs.*; do
        [ -e "$f" ] || continue
        unit=$(systemctl list-units --type=service --state=active,activating --plain \
            --no-legend 'usb-*-gadget.service' | awk 'NR==1{print $1}')
        [ -z "$unit" ] || exec systemctl restart "$unit"
    done
    echo "" > "$u"
    echo "$udc" > "$u"
    exit 0
done
