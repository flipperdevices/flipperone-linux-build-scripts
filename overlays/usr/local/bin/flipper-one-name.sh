#!/bin/sh
# flipper-one-name.sh - print this Flipper One's name, the one fused into the MCU's OTP at the
# factory, as the MCU driver reports it. Prints nothing and exits 1 when there is none to report:
# another board, a kernel without the MCU driver (the BSP one), an MCU firmware or a driver that
# does not report it yet, or an OTP that was never written.
#
# The name is read, never derived or stored here: it lives on the control board, so every
# profile's root sees the same one, as does MCU mode. Only what the MCU firmware takes when the
# name is written is passed on, 1 to 31 of [A-Za-z0-9._-], and only with a letter or digit in it,
# so it is safe as it is in an SSID, a sed replacement or XML, and in a hostname once lowercased
# with '.' and '_' made '-'.
export LC_ALL=C

for attr in /sys/bus/i2c/drivers/flipper-one-mcu/*/device_name; do
    [ -r "$attr" ] || continue
    # The name ends at the first newline or NUL, as the MCU's C string does
    name=$(tr '\0' '\n' 2>/dev/null <"$attr" | head -n 1)
    case $name in
        '' | *[!A-Za-z0-9._-]*) continue ;;
        *[A-Za-z0-9]*) ;;
        *) continue ;;
    esac
    [ ${#name} -le 31 ] || continue
    printf '%s\n' "$name"
    exit 0
done
exit 1
