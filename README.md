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

Please note that as of August 2025, the only RK3576 based board supported by the unmodified upstream U-boot is Firefly ROC-RK3576-PC.

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

## Assembling full disk images for SD/eMMC

Please note that as of August 2025, upstream U-boot doesn't have a driver for the Rockchip UFS controller, so it cannot boot from UFS.

Prepare the kernel and U-boot images per the above instructions, then run:

```bash
./build-image.sh
```

It will produce compressed disk images for all boards for which you have compiled U-boot images. Linux kernel and root filesystem images will be the same in all of them.

## Writing the full disk image to SD/MMC

### Flashing to an SD card

To produce a bootable SD card with your newly built Debian image, connect it to your host computer (e.g. through a card reader).

If you have a built-in SD card slot, you may use that, and the card will likely show up as `/dev/mmcblkX` (where `X` is the number identifying the respective SD/MMC controller, likely `0` if you only have one).

If you are using a USB card reader, the card will likely show up as `/dev/sdX` (where `X` is a lowercase letter). In this latter case you need to be triple careful, because any SATA or SCSI storage devices will also share the same naming scheme, and if you have important data on any other `/dev/sdX` device (such as your main system disk being called something like `/dev/sda`) you might end up inadvertently overwriting it if you pick the wrong one in the below commands, losing all your data. Please be careful.

```bash
sudo bmaptool copy out/debian-<your_board>.img.gz /dev/sdX
```

### Flashing to eMMC using a USB cable and Maskrom

Rockchip devices include a special built-in mode called Maskrom, which allows flashing the board over a USB connection even if the board contains no bootloader or it is corrupted.

This mode is activated by holding down a MASKROM button when the power supply gets connected.

- Instructions for Radxa Rock 4D: https://docs.radxa.com/en/rock4/rock4d/hardware-use/maskrom?maskrom-display=Linux%2FMacOS. Connect a USB A to A cable (or Type C to USB A, depending on you host computer’s available USB ports) to the top USB 3.0 blue port, hold the MASKROM button and apply power to the board as usual via its Type C DC IN. Note that eMMC modules cannot be used together with the onboard SPI flash, as they share pins internally
- Instructions for ArmSoM Sige5: https://docs.armsom.org/getting-start/flash-img#241-device-connection. Connect a USB A to Type C cable (or Type C to Type C, depending on your host computer’s available USB ports) to the Type C OTG port (marked TYPEC on the board), hold the MASKROM button and apply power to the board as usual via its Type C DC IN

You should then see something like this in `lsusb` command output:

```bash
Bus 002 Device 011: ID 2207:350e Fuzhou Rockchip Electronics Company
```

Your device is now ready for programming over the Rockusb protocol.

```bash
# Boot the board in USB upload mode
sudo rockusb download-boot prebuilt/u-boot/<your_board>/rk3576_spl_loader_*.bin

sudo rockusb write-file 0 out/debian-<your_board>.img.gz
```
