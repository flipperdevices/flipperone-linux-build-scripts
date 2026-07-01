#!/bin/bash

set -e

if [ "$#" -gt 0 ]; then
	exec "$@"
fi

./build-uboot.sh
./build-kernel-mainline.sh
./build-kernel-bsp.sh
exec ./build-images.sh
