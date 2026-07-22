#!/bin/sh
# USB MTP gadget serving /home (needs the umtprd daemon). Thin preset over usb-gadget-setup.sh.
exec usb-gadget-setup.sh --name mtpg --pid 0xF124 --product "Flipper One USB MTP" --mtp "$@"
