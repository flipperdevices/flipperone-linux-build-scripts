# Linux system image build scripts for RK3576 based boards

The scripts in this repository produce disk images for Rockchip RK3576 based boards, ready to be flashed to an SD card or uploaded to internal storage via a USB connection and Maskrom mode.

They are meant to be run on Debian 13 (trixie) or later. It's probably possible to use different distributions too, but you'll need to find the right prerequisites yourself. Your mileage may vary.

Note that while you can compile all of this software by hand by running the scripts in this repository, you don't necessarily have to. Most commits include a small green checkmark in the GitHub interface next to the commit message (or a red cross if we are less lucky), which link to a page in our [Buildbot web interface](https://linux-images.flipp.dev/) with full build logs and links to [pre-built images for all relevant boards](https://dl-linux-images.flipp.dev/full-img/), which our automated build system produces whenever something updates either in this repository or in one of its dependencies.
> Pre-built images for all supported boards are available at [dl-linux-images.flipp.dev](https://dl-linux-images.flipp.dev/full-img/) and are updated automatically on every commit. Building from source is only necessary if you want to modify the system.

## Related repositories

This repo contains build scripts only. The full system is assembled from several components:

| Repository | Description |
|---|---|
| **flipperone-linux-build-scripts** | Build scripts that assemble complete disk images for RK3576-based boards |
| [flipper-linux-kernel](https://github.com/flipperdevices/flipper-linux-kernel) | Linux kernel patches and configuration for Flipper One RK3576-based boards |
| [flipperone-mcu-firmware](https://github.com/flipperdevices/flipperone-mcu-firmware) | Firmware for the low-power RP2350 MCU |

The build scripts pull the kernel and other components automatically — you don't need to clone other repos manually unless you want to modify them.


## Quick start with Dev Container (VS Code)

1. Install [VS Code](https://code.visualstudio.com/) and the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
2. Clone this repository and open it in VS Code
3. Press `F1` and select **"Dev Containers: Reopen in Container"**
4. Wait for the container to build (first time only)
5. Run build scripts from the integrated terminal:
   ```bash
   ./build-uboot.sh
   ./build-kernel-mainline.sh
   ./build-images.sh
   ```
6. Find build artifacts in the `out/` directory

## Quick start with Docker

The Docker image contains the dependencies required to build Flipper One Linux images locally. Build artifacts are written to the `out/` directory on the host.

```bash
# Clone repo
git clone https://github.com/flipperdevices/flipperone-linux-build-scripts
cd flipperone-linux-build-scripts

# Build Docker image
docker build -t flipperone-linux-build-scripts .

# Build OS images
mkdir -p out
docker run --privileged --rm -v "$(pwd)/out:/artifacts" \
    flipperone-linux-build-scripts
```

After the build finishes, generated images can be found in `out/images/`.

### Flashing to Radxa 4D eMMC via USB

Switch Radxa 4D into Maskrom mode and verify that it is visible:

```bash
rockusb list
```

Upload the bootloader:

```bash
rockusb download-boot out/u-boot/rock-4d/rk3576_spl_loader_*.bin
```

Flash the image to eMMC:

```bash
rockusb write-bmap out/images/debian-rock-4d-*.img.gz
```

Reboot the board:

```bash
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
sudo apt install systemd-resolved pipx pigz cargo parted fdisk
cargo install --git https://github.com/rorosen/zeekstd.git zeekstd_cli
sudo install -m 755 ~/.cargo/bin/zeekstd /usr/local/bin/
sudo pipx install --global git+https://github.com/flipperdevices/bmaptool.git@flipper-devel

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
sudo bmaptool copy out/images/debian-<your_board>.img.gz /dev/sdX
```

### Flashing to eMMC using a USB cable and Maskrom

Rockchip devices include a special built-in mode called Maskrom, which allows flashing the board over a USB connection even if the board contains no bootloader or it is corrupted.

This mode is activated by holding down a MASKROM button when the power supply gets connected.

- Instructions for [Radxa Rock 4D](https://docs.radxa.com/en/rock4/rock4d/hardware-use/maskrom?maskrom-display=Linux%2FMacOS): Connect a USB A to A cable (or Type C to USB A, depending on your host computer's available USB ports) to the top USB 3.0 blue port, hold the MASKROM button and apply power to the board as usual via its Type C DC IN. Note that eMMC modules cannot be used together with the onboard SPI flash, as they share pins internally
- Instructions for [ArmSoM Sige5](https://docs.armsom.org/getting-start/flash-img#241-device-connection): Connect a USB A to Type C cable (or Type C to Type C, depending on your host computer's available USB ports) to the Type C OTG port (marked TYPEC on the board), hold the MASKROM button and apply power to the board as usual via its Type C DC IN

You should then see something like this in `lsusb` command output:

```bash
Bus 002 Device 011: ID 2207:350e Fuzhou Rockchip Electronics Company
```

Your device is now ready for programming over the Rockusb protocol.

```bash
# Boot the board in USB upload mode
sudo rockusb download-boot prebuilt/u-boot/<your_board>/rk3576_spl_loader_*.bin

sudo rockusb write-bmap out/images/debian-<your_board>.img.gz
```
