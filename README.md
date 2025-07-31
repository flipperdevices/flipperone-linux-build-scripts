# Linux system image build scripts for RK3576 based boards

The scripts in this repository produce disk images for Rockchip RK3576 based boards, ready to be flashed to an SD card or uploaded to internal storage via a USB connection and Maskrom mode.

They are meant to be run on a Debian 13 (trixie) or later systems. It's probably possible to use different distributions too, but you'll need to find the right prerequisites yourself. Your mileage may vary.

### Prerequisites

For building the bootloader:

```bash
sudo apt install git build-essential crossbuild-essential-arm64 bison flex python3-dev python3-libfdt python3-setuptools swig libssl-dev gnutls-dev python3-pyelftools
```

For building the kernel:

```bash
sudo dpkg --add-architecture arm64
sudo apt update
sudo apt install git build-essential crossbuild-essential-arm64 bc bison flex libssl-dev libdw-dev libelf-dev debhelper libssl-dev:arm64
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
