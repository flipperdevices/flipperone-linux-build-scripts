#!/bin/sh
set -e

G=/sys/kernel/config/usb_gadget/ncmg
SERIAL="0123456789"
MANUFACTURER="Flipper FZCO"
PRODUCT="Flipper One USB Ethernet"
USB_VID="0x37C1"
USB_PID="0xF121"

usb_ncm_start()
{
    modprobe usb_f_ncm

    # 1) Create gadget
    mkdir -p $G
    echo "$USB_VID" > $G/idVendor
    echo "$USB_PID" > $G/idProduct
    echo 0x0100 > $G/bcdDevice
    echo 0x0300 > $G/bcdUSB        # 0x0200 for USB 2.0; 0x0300 for USB 3.x

    # Optional: "composite" device class helps some hosts
    echo 0xEF > $G/bDeviceClass
    echo 0x02 > $G/bDeviceSubClass
    echo 0x01 > $G/bDeviceProtocol

    # 2) Strings
    mkdir -p $G/strings/0x409
    echo "$SERIAL" > $G/strings/0x409/serialnumber
    echo "$MANUFACTURER" > $G/strings/0x409/manufacturer
    echo "$PRODUCT" > $G/strings/0x409/product

    # 3) Configuration
    mkdir -p $G/configs/c.1
    echo 250 > $G/configs/c.1/MaxPower  # mA @ USB2
    mkdir -p $G/configs/c.1/strings/0x409
    echo "CDC-NCM" > $G/configs/c.1/strings/0x409/configuration

    # 4) NCM function
    mkdir -p $G/functions/ncm.usb0
    # Stable MACs; first byte even and LAA bit set
    echo "02:1A:7D:01:02:03" > $G/functions/ncm.usb0/dev_addr
    echo "02:1A:7D:01:02:04" > $G/functions/ncm.usb0/host_addr
    # Optional tuning (defaults are fine on most kernels)
    # echo 16384 > $G/functions/ncm.usb0/tx_max
    # echo 16384 > $G/functions/ncm.usb0/rx_max
    # echo 32    > $G/functions/ncm.usb0/ntb_input_size
    ln -s $G/functions/ncm.usb0 $G/configs/c.1/

    # 5) Bind to a UDC
    UDC=$(ls /sys/class/udc | head -n1)
    [ -n "$UDC" ]
    echo "$UDC" > $G/UDC

    # NetworkManager brings up the interface via flipusb0-shared connection
}

usb_ncm_stop()
{
    if [ -d "$G" ]; then
        # Unbind from UDC
        echo "" > $G/UDC ||:
        
        # Remove configuration symlink
        rm -f $G/configs/c.1/ncm.usb0 ||:
        
        # Remove directories in reverse order
        rmdir $G/configs/c.1/strings/0x409 ||:
        rmdir $G/configs/c.1 ||:
        rmdir $G/functions/ncm.usb0 ||:
        rmdir $G/strings/0x409 ||:
        rmdir $G ||:
    fi
}

case "$1" in
    start)
        usb_ncm_start
        ;;
    stop)
        usb_ncm_stop
        ;;
    restart)
        usb_ncm_stop
        usb_ncm_start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
