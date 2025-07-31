# Linux system image build scripts for RK3576 based boards

The scripts in this repository produce disk images for Rockchip RK3576 based boards, ready to be flashed to an SD card or uploaded to internal storage via a USB connection and Maskrom mode.

They are meant to be run on a Debian 13 (trixie) or later systems. It's probably possible to use different distributions too, but you'll need to find the right prerequisites yourself. Your mileage may vary.

## Prerequisites

For building the bootloader:

```bash
sudo apt install git build-essential crossbuild-essential-arm64 bison flex python3-dev python3-libfdt python3-setuptools swig libssl-dev gnutls-dev python3-pyelftools
```

For building the kernel:

```bash
sudo dpkg --add-architecture arm64
sudo apt update
sudo apt install git build-essential crossbuild-essential-arm64 bc bison flex libssl-dev libdw-dev libelf-dev debhelper libssl-dev:arm64 rsync
```

For fetching vendor DTS files (if using a Rockchip BSP kernel):

```bash
sudo apt install wget gdown repo
```

For assembling complete disk images:

```bash
sudo apt install debos systemd-resolved bmap-tools pigz
```

For uploading images over USB:

```bash
sudo apt install rockusb
```

## Building Linux kernel packages

### Mainline kernel

To simply fetch and build the most recent mainline Linux kernel:

```bash
./build-kernel-mainline.sh
```

To rebuild without re-downloading:

```bash
KEEP_SRC=yes ./build-kernel-mainline.sh
```

To incrementally update downloaded sources without full fresh clone:

```bash
KEEP_SRC=update ./build-kernel-mainline.sh
```

To download and build a mainline-based Linux kernel from any repo other than Linus Torvalds' master branch:

```bash
LINUX_GIT=https://gitlab.collabora.com/hardware-enablement/rockchip-3588/linux.git LINUX_BRANCH=rockchip-devel ./build-kernel-mainline.sh
```

## Building bootloader images

To simply fetch and build the most recent upstream U-boot with opensource TF-A:

```bash
./build-uboot.sh
```

Please note that as of July 2025, the only RK3576 based board supported by the unmodified upstream U-boot is Firefly ROC-RK3576-PC.

To build for other boards, alternative U-boot source trees can be used, such as:

```bash
BOARD=sige5 UBOOT_GIT="https://source.denx.de/u-boot/contributors/kwiboo/u-boot.git" UBOOT_BRANCH="rk3576" ./build-uboot.sh
BOARD=omni3576 KEEP_SRC=yes ./build-uboot.sh
BOARD=nanopi-m5 KEEP_SRC=yes ./build-uboot.sh
BOARD=rock-4d KEEP_SRC=yes ./build-uboot.sh
```

To use Rockchip binary BL31 instead of opensource TF-A:

```bash
USE_BL31=vendor BOARD=sige5 UBOOT_GIT="https://source.denx.de/u-boot/contributors/kwiboo/u-boot.git" UBOOT_BRANCH="rk3576" ./build-uboot.sh
USE_BL31=vendor BOARD=omni3576 KEEP_SRC=yes ./build-uboot.sh
USE_BL31=vendor BOARD=nanopi-m5 KEEP_SRC=yes ./build-uboot.sh
USE_BL31=vendor BOARD=rock-4d KEEP_SRC=yes ./build-uboot.sh
```
