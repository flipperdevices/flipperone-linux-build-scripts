#!/bin/sh
# Gather the EXT connector's SoC GPIOs into a GPIO chip of their own, ext_gpio, so
# access can be granted to them and to nothing else on the board.
#
# Lines are added in connector pin order, pin 5 first, and named as on the schematic.
# A pin an overlay has given to a bus is left out: driving it as a GPIO would take it
# from the bus.
set -eu

cfg=/sys/kernel/config/gpio-aggregator/ext_gpio
pins=/sys/kernel/debug/pinctrl/pinctrl-rockchip-pinctrl/pinmux-pins
[ -e "$cfg" ] && exit 0

claimed() {
    [ -r "$pins" ] && grep "(gpio4-$1):" "$pins" | grep -qv "(MUX UNCLAIMED)"
}

mkdir "$cfg"
n=0
for line in A3:3 A2:2 A5:5 A4:4 A7:7 A6:6 B1:9 B0:8 B3:11 B2:10 B5:13 B4:12; do
    offset=${line#*:}
    claimed "$offset" && continue
    mkdir "$cfg/line$n"
    echo gpio4 > "$cfg/line$n/key"
    echo "$offset" > "$cfg/line$n/offset"
    echo "GPIO_${line%:*}" > "$cfg/line$n/name"
    n=$((n + 1))
done

if [ "$n" = 0 ]; then
    rmdir "$cfg"
    exit 0
fi
echo 1 > "$cfg/live"
