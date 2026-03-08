# Linux system image build scripts for RK3576 based boards

The scripts in this repository produce disk images for Rockchip RK3576 based boards, ready to be flashed to an SD card or uploaded to internal storage via a USB connection and Maskrom mode.

They are meant to be run on a Debian 13 (trixie) or later systems. It's probably possible to use different distributions too, but you'll need to find the right prerequisites yourself. Your mileage may vary.


## Quick start with Docker

**TODO**: Move to Docker Hub

```bash
# Clone repo 
git clone https://github.com/flipperdevices/rk3576-linux-build 
cd rk3576-linux-build

# Build docker image and start container
docker build -t rk3576-linux-build .
docker run --privileged --rm -v $(pwd)/out:/artifacts \
	rk3576-linux-build

# Flash image to Radxa 4D MicroSD card via USB

# 1. Switch Radxa 4D into Maskrom mode and verify it
# rockusb should work inside Docker container becuase of privileged mode
rockusb list

# 2. Upload bootloader to Radxa 4D
rockusb download-boot out/u-boot/rock-4d/rk3576_spl_loader_*.bin

# 3. Flash image to MicroSD card
rockusb write-bmap out/images/debian-rock-4d-20250824-0021.img.gz

# 4. Reboot the board
rockusb reset-device
```


## Prepare build system manually

For building the bootloader:

```bash
sudo apt install git build-essential crossbuild-essential-arm64 bison flex python3-dev python3-libfdt python3-setuptools swig libssl-dev gnutls-dev python3-pyelftools
```

For building the kernel:

```bash
sudo dpkg --add-architecture arm64
sudo apt update
sudo apt install git build-essential crossbuild-essential-arm64 bc bison flex imagemagick libssl-dev libdw-dev libelf-dev debhelper libssl-dev:arm64 rsync
```

For fetching vendor DTS files (if using a Rockchip BSP kernel):

```bash
sudo apt install wget gdown repo
```

For assembling complete disk images:

```bash
sudo apt install systemd-resolved bmap-tools pigz cargo fakemachine
cargo install --git https://github.com/rorosen/zeekstd.git zeekstd_cli
sudo install -m 755 ~/.cargo/bin/zeekstd /usr/local/bin/

echo deb http://ftp.debian.org/debian testing main non-free contrib | sudo tee /etc/apt/sources.list.d/testing.list
cat <<EOF | sudo tee /etc/apt/preferences.d/pins
Package: *
Pin: release a=stable
Pin-Priority: 700

Package: *
Pin: release a=testing
Pin-Priority: 650
EOF

sudo apt update
sudo apt install -t testing debos
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

### BSP kernel

To simply fetch and build the most recent Rockchip publicly released kernel:

```bash
./build-kernel-bsp.sh
```

To rebuild without re-downloading:

```bash
KEEP_SRC=yes ./build-kernel-bsp.sh
```

To incrementally update downloaded sources without full fresh clone:

```bash
KEEP_SRC=update ./build-kernel-bsp.sh
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
./build-images.sh
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

sudo rockusb write-bmap out/debian-<your_board>.img.gz
```

## Supported boards
| Board name | Our target name | Comment |
|---|---|---|
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/a05325e0-9e03-4a07-b39c-12d618a95469"><br><sub>Flipper One Prototype<br></sub></div> |flipper-one  | Our current Flipper One prototype |
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/3f8d7d73-70f3-4c02-a290-6f2f51621499"><br><sub><a href="https://docs.banana-pi.org/en/BPI-M5/BananaPi_BPI-M5_Pro">Banana Pi BPI-M5 Pro</a><br>aka <a href="https://www.armsom.org/sige5">Armsom Sige5</a></sub></div> | sige5 | Don't be confused with 2 different names `Banana Pi BPI-M5 Pro` and `Armsom Sige5`, its the same product. Has DisplayPort on USB-C. Recommended board. |
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/135c0fca-3dfe-4d33-b239-10184154935c"><br><sub><a href="https://radxa.com/products/rock4/4d/">Radxa ROCK 4D</a></sub></div> | rock-4d | No DisplayPort on USB-C. To enter Maskrom USB-A to USB-A cable required |
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/605a8b7f-a85e-4735-8198-81005ed4ec5c"><br><sub><a href="https://www.friendlyelec.com/index.php?route=product/product&product_id=309">NanoPi M5</a></sub></div> | nanopi-m5 |  |
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/b297e6ab-88d8-4085-a0d2-b989462414b1"><br><sub><a href="https://www.luckfox.com/EN-Luckfox-Omni3576">Luckfox Omni3576</a></sub></div> | omni3576 |  |
| <div align="center"><img width="200" src="https://dummyimage.com/200x120/cccccc/000000&text=EVB1"><br><sub>Rockchip RK3576 Evaluation Board EVB1</sub></div> | evb1 | Official Rockchip RK3576 Evaluation board EVB1. Not available for sale.  |



