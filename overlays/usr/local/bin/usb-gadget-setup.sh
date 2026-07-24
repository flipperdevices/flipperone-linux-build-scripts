#!/bin/sh
# usb-gadget-setup.sh {start|stop|restart|eject} [options] - build a USB gadget from the
# selected functions and bind it to the dwc3 UDC. Used directly, or via the thin presets
# usb-ncm-gadget.sh / usb-msc-gadget.sh / usb-ncm-msc-gadget.sh / usb-ncm-msc-mtp-gadget.sh.
#
# Functions can be combined into one composite gadget (one UDC, one device). The storage
# LUN starts empty; a medium is loaded by writing lun.0/file, so sharing or swapping media
# never unbinds and other functions (e.g. NCM Ethernet) do not blip.
#
#   --ncm|--ecm|--eem|--rndis   add a USB Ethernet function (kernel)
#   --acm                       add a USB serial (CDC-ACM) function (kernel)
#   --storage                   add a mass_storage LUN (implied by a medium option)
#   --mtp                       add MTP over FunctionFS (needs the umtprd daemon; serves
#                               the paths in /etc/umtprd/umtprd.conf, /home by default)
#   --name NAME                 configfs gadget name (default: flipper)
#   --pid HEX / --product STR   idProduct / iProduct (idVendor fixed 0x37C1, serial auto)
#   --sda|--sdcard|--iso FILE   storage medium
#   --RW|--RO|--cdrom           storage access mode (default auto; --RW demoted if mounted)
set -e

NCM_FUNC=ncm.usb0
ECM_FUNC=ecm.usb0
EEM_FUNC=eem.usb0
RNDIS_FUNC=rndis.usb0
ACM_FUNC=acm.gs0
MSC_FUNC=mass_storage.0
MTP_FUNC=ffs.mtp
FFS_INST=mtp
FFS_DIR=/dev/ffs-mtp
INQUIRY="Flipper Storage"
SDA=/dev/sda
SDCARD="${SDCARD:-/dev/mmcblk0}"
DEV_ADDR="02:1A:7D:01:02:03"
HOST_ADDR="02:1A:7D:01:02:04"
USB_VID="0x37C1"
MANUFACTURER="Flipper FZCO"
# CPU serial from DT (set by U-Boot), else recomputed from OTP, else machine-id. Mass-storage
# BOT needs >=12 uppercase hex, so strip to hex and uppercase (harmless for other functions).
SERIAL=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || rk3576_cpu_serial.sh 2>/dev/null | tail -n1 | awk -F"\t" '{ print $2; }' || cat /etc/machine-id 2>/dev/null)
SERIAL=$(printf '%s' "$SERIAL" | tr -cd '0-9A-Fa-f' | tr 'a-f' 'A-F')
: "${SERIAL:=0123456789AB}"

NAME=""
USB_PID="0xF120"
PRODUCT="Flipper One"
WANT_NCM=0; WANT_ECM=0; WANT_EEM=0; WANT_RNDIS=0; WANT_ACM=0; WANT_STORAGE=0; WANT_MTP=0
BACKING=""
ISO_SET=0
CDROM=0
MODE=auto

disk_in_use()
{
    # true if $1 or any of its partitions is mounted here
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -nro MOUNTPOINT "$1" 2>/dev/null | grep -q .
    else
        awk -v d="$1" '$1==d || $1 ~ ("^" d "(p?[0-9]+)$") {f=1} END{exit !f}' /proc/mounts
    fi
}

# function directory names to create for the requested functions, one per line
wanted_funcs()
{
    [ "$WANT_NCM" = 1 ]     && echo "$NCM_FUNC"
    [ "$WANT_ECM" = 1 ]     && echo "$ECM_FUNC"
    [ "$WANT_EEM" = 1 ]     && echo "$EEM_FUNC"
    [ "$WANT_RNDIS" = 1 ]   && echo "$RNDIS_FUNC"
    [ "$WANT_ACM" = 1 ]     && echo "$ACM_FUNC"
    [ "$WANT_STORAGE" = 1 ] && echo "$MSC_FUNC"
    [ "$WANT_MTP" = 1 ]     && echo "$MTP_FUNC"
    :
}

modprobe_funcs()
{
    [ "$WANT_NCM" = 1 ]     && { modprobe usb_f_ncm ||:; }
    [ "$WANT_ECM" = 1 ]     && { modprobe usb_f_ecm ||:; }
    [ "$WANT_EEM" = 1 ]     && { modprobe usb_f_eem ||:; }
    [ "$WANT_RNDIS" = 1 ]   && { modprobe usb_f_rndis ||:; }
    [ "$WANT_ACM" = 1 ]     && { modprobe usb_f_acm ||:; }
    [ "$WANT_STORAGE" = 1 ] && { modprobe usb_f_mass_storage ||:; }
    [ "$WANT_MTP" = 1 ]     && { modprobe usb_f_fs ||:; }
    :
}

create_func()
{
    [ -d "$G/functions/$1" ] && return 0
    mkdir -p $G/functions/$1
    case "$1" in
        ncm.*|ecm.*|eem.*|rndis.*)
            echo "$DEV_ADDR" > $G/functions/$1/dev_addr
            echo "$HOST_ADDR" > $G/functions/$1/host_addr ;;
        mass_storage.*)
            echo 1 > $G/functions/$1/lun.0/removable
            echo "$INQUIRY" > $G/functions/$1/lun.0/inquiry_string ;;
    esac
    ln -s $G/functions/$1 $G/configs/c.1/
}

# eject any loaded medium; forced_eject overrides a host "prevent removal" lock
eject_lun()
{
    L=$G/functions/$MSC_FUNC/lun.0
    [ -e "$L/file" ] || return 0
    [ -n "$(cat "$L/file" 2>/dev/null)" ] || return 0
    if [ -e "$L/forced_eject" ]; then echo 1 > "$L/forced_eject"; else echo "" > "$L/file"; fi
}

load_medium()
{
    LUN=$G/functions/$MSC_FUNC/lun.0
    if [ "$ISO_SET" = 1 ]; then
        RW=0
    else
        if disk_in_use "$BACKING"; then INUSE=1; else INUSE=0; fi
        case "$MODE" in
            ro) RW=0 ;;
            rw) RW=1 ;;
            *)  if [ "$INUSE" = 1 ]; then RW=0; else RW=1; fi ;;
        esac
        if [ "$RW" = 1 ] && [ "$INUSE" = 1 ]; then
            echo "$BACKING is mounted by this system; forcing read-only to avoid corruption." >&2
            RW=0
        fi
    fi
    [ "$CDROM" = 1 ] && RW=0

    eject_lun
    echo "$CDROM" > $LUN/cdrom
    if [ "$RW" = 1 ]; then echo 0 > $LUN/ro; else echo 1 > $LUN/ro; fi
    echo "$BACKING" > $LUN/file
}

# MTP needs a userspace responder (umtprd) to write the FunctionFS descriptors before the
# UDC is bound; the endpoints ep1/ep2 appear once it has. Storage paths come from its conf.
mtp_up()
{
    mkdir -p "$FFS_DIR"
    grep -q " $FFS_DIR functionfs " /proc/mounts || mount -t functionfs "$FFS_INST" "$FFS_DIR"
    if ! pgrep -x umtprd >/dev/null 2>&1; then umtprd & fi
    i=0
    while [ ! -e "$FFS_DIR/ep1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ -e "$FFS_DIR/ep1" ] || { echo "umtprd did not bring up FunctionFS" >&2; return 1; }
}

mtp_down()
{
    pkill -x umtprd 2>/dev/null ||:
    grep -q " $FFS_DIR functionfs " /proc/mounts && umount "$FFS_DIR" ||:
}

build_base()
{
    mkdir -p $G
    echo "$USB_VID" > $G/idVendor
    echo "$USB_PID" > $G/idProduct
    echo 0x0100 > $G/bcdDevice
    echo 0x0300 > $G/bcdUSB
    # IAD/composite device class when a CDC function (ncm/ecm/eem/rndis/acm, each
    # multi-interface) is present or more than one function is combined; a lone
    # single-interface function (mass storage or MTP) keeps the default class 0.
    if [ "$WANT_NCM$WANT_ECM$WANT_EEM$WANT_RNDIS$WANT_ACM" != "00000" ] || [ "$(wanted_funcs | grep -c .)" -gt 1 ]; then
        echo 0xEF > $G/bDeviceClass
        echo 0x02 > $G/bDeviceSubClass
        echo 0x01 > $G/bDeviceProtocol
    fi

    mkdir -p $G/strings/0x409
    echo "$SERIAL" > $G/strings/0x409/serialnumber
    echo "$MANUFACTURER" > $G/strings/0x409/manufacturer
    echo "$PRODUCT" > $G/strings/0x409/product

    mkdir -p $G/configs/c.1
    echo 250 > $G/configs/c.1/MaxPower
    mkdir -p $G/configs/c.1/strings/0x409
    echo "$PRODUCT" > $G/configs/c.1/strings/0x409/configuration
}

start()
{
    [ -n "$(wanted_funcs)" ] || { echo "No functions selected" >&2; exit 1; }
    modprobe_funcs
    [ -d "$G" ] || build_base

    # adding a function needs the gadget unbound; media swaps below do not
    relink=0
    for f in $(wanted_funcs); do [ -d "$G/functions/$f" ] || relink=1; done
    [ "$relink" = 1 ] && [ -n "$(cat $G/UDC 2>/dev/null)" ] && echo "" > $G/UDC
    for f in $(wanted_funcs); do create_func "$f"; done

    [ "$WANT_STORAGE" = 1 ] && [ -n "$BACKING" ] && load_medium
    [ "$WANT_MTP" = 1 ] && mtp_up

    # bind if not bound (also the reconnect path after a replug)
    if [ -z "$(cat $G/UDC 2>/dev/null)" ]; then
        # Prefer a hardware UDC; skip virtual ones (e.g. usbip-vudc.0) that would
        # "bind" fine but expose nothing on the physical Type-C port.
        udc=$(ls /sys/class/udc 2>/dev/null | grep -v vudc | head -n1)
        udc=${udc:-$(ls /sys/class/udc 2>/dev/null | head -n1)}
        [ -n "$udc" ] || { echo "No UDC available" >&2; exit 1; }
        # only one gadget can hold the single dwc3 UDC; refuse with a clear message
        for other in /sys/kernel/config/usb_gadget/*/UDC; do
            [ -e "$other" ] || continue
            [ "$other" = "$G/UDC" ] && continue
            if [ "$(cat "$other" 2>/dev/null)" = "$udc" ]; then
                echo "UDC $udc is busy (held by $(basename "$(dirname "$other")")); stop that gadget first" >&2
                exit 1
            fi
        done
        # Early in boot the dwc3 controller may not be ready yet: writing UDC fails
        # with -19 (ENODEV) / EBUSY and leaves it empty, so the gadget never comes
        # up on the port. Retry until the bind sticks (up to ~5s).
        i=0
        while :; do
            echo "$udc" > "$G/UDC" 2>/dev/null
            [ -n "$(cat $G/UDC 2>/dev/null)" ] && break
            i=$((i + 1))
            [ "$i" -ge 15 ] && { echo "UDC $udc not ready after 15s" >&2; break; }
            sleep 1
        done
    fi
}

stop()
{
    [ -d "$G" ] || return 0
    [ -n "$(cat $G/UDC 2>/dev/null)" ] && echo "" > $G/UDC
    [ -d "$G/functions/$MSC_FUNC" ] && eject_lun
    [ -d "$G/functions/$MTP_FUNC" ] && mtp_down
    for f in $NCM_FUNC $ECM_FUNC $EEM_FUNC $RNDIS_FUNC $ACM_FUNC $MSC_FUNC $MTP_FUNC; do
        [ -e "$G/configs/c.1/$f" ] && rm -f "$G/configs/c.1/$f" ||:
        [ -d "$G/functions/$f" ] && { rmdir "$G/functions/$f" ||:; }
    done
    rmdir $G/configs/c.1/strings/0x409 ||:
    rmdir $G/configs/c.1 ||:
    rmdir $G/strings/0x409 ||:
    rmdir $G ||:
}

usage() {
    cat <<EOF
Usage: $0 {start|stop|restart|eject} [options]
  --ncm|--ecm|--eem|--rndis   add a USB Ethernet function
  --acm                       add a USB serial (CDC-ACM) function
  --storage                   add a mass_storage LUN (implied by a medium option)
  --mtp                       add MTP over FunctionFS (needs umtprd; serves /etc/umtprd/umtprd.conf)
  --name NAME                 configfs gadget name (default: flipper)
  --pid HEX                   idProduct (idVendor fixed 0x37C1, serial auto from CPU)
  --product STR               iProduct string
  --sda|--sdcard|--iso FILE   storage medium
  --RW|--RO|--cdrom           storage access mode (default auto; --RW demoted on a mounted disk)
  -h,--help                   show this help
EOF
}

ACTION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ncm)      WANT_NCM=1 ;;
        --ecm)      WANT_ECM=1 ;;
        --eem)      WANT_EEM=1 ;;
        --rndis)    WANT_RNDIS=1 ;;
        --acm)      WANT_ACM=1 ;;
        --storage)  WANT_STORAGE=1 ;;
        --mtp)      WANT_MTP=1 ;;
        --name)     shift; NAME="${1:-}" ;;
        --name=*)   NAME="${1#--name=}" ;;
        --pid)      shift; USB_PID="${1:-}" ;;
        --pid=*)    USB_PID="${1#--pid=}" ;;
        --product)  shift; PRODUCT="${1:-}" ;;
        --product=*) PRODUCT="${1#--product=}" ;;
        --sda)      BACKING="$SDA"; WANT_STORAGE=1 ;;
        --sdcard)   BACKING="$SDCARD"; WANT_STORAGE=1 ;;
        --iso)      shift; BACKING="${1:-}"; ISO_SET=1; WANT_STORAGE=1 ;;
        --iso=*)    BACKING="${1#--iso=}"; ISO_SET=1; WANT_STORAGE=1 ;;
        --cdrom)    CDROM=1; WANT_STORAGE=1 ;;
        --RW|--rw)  MODE=rw ;;
        --RO|--ro)  MODE=ro ;;
        -h|--help)  usage; exit 0 ;;
        start|stop|restart|eject) ACTION="$1" ;;
        -?*)        echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)          usage >&2; exit 1 ;;
    esac
    shift
done

: "${NAME:=flipper}"
G=/sys/kernel/config/usb_gadget/$NAME
[ "$ISO_SET" != 1 ] || [ -f "$BACKING" ] || { echo "ISO not found: $BACKING" >&2; exit 1; }

case "$ACTION" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    eject)   [ -d "$G" ] && eject_lun ;;
    *)       usage >&2; exit 1 ;;
esac
