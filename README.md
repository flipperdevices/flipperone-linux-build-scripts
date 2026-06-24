# Linux system image build scripts for RK3576 based boards

The scripts in this repository produce disk images for Rockchip RK3576 based boards, ready to be flashed to an SD card or uploaded to internal storage via a USB connection and Maskrom mode.

You don't necessarily have to build images yourself. Most commits include a small green checkmark in the GitHub interface next to the commit message (or a red cross if we are less lucky), which links to a page in our [Buildbot web interface](https://linux-images.flipp.dev/) with full build logs and links to [pre-built images for all relevant boards](https://dl-linux-images.flipp.dev/full-img/), which our automated build system produces whenever something updates either in this repository or in one of its dependencies. Building from source is only necessary if you want to modify the system.

---

## Repos structure

This repo contains build scripts only. The full system is assembled from several components:

| Repository | Description |
|---|---|
| **flipperone-linux-build-scripts** | Build scripts that assemble complete disk images for RK3576-based boards (this repo) |
| [flipper-linux-kernel](https://github.com/flipperdevices/flipper-linux-kernel) | Linux kernel patches and configuration for Flipper One RK3576-based boards |
| [flipperone-mcu-firmware](https://github.com/flipperdevices/flipperone-mcu-firmware) | Firmware for the low-power RP2350 MCU |
| [flipperdevices/u-boot](https://github.com/flipperdevices/u-boot) | Flipper fork of U-Boot; adds defconfigs for Flipper One and EVB1 on top of upstream |
| [flipperdevices/rkbin](https://github.com/flipperdevices/rkbin) | Rockchip binary firmware blobs — DDR init blob and prebuilt Maskrom USB loader (always required), plus vendor BL31 when `USE_BL31=vendor` |
| [ARM-software/arm-trusted-firmware](https://github.com/ARM-software/arm-trusted-firmware) | Open-source Trusted Firmware-A; used as BL31 by default |

The build scripts pull the kernel and other components automatically — you don't need to clone other repos manually unless you want to modify them.

### What's in this repo

Build scripts (run them in order):

| Script | What it does |
|---|---|
| `build-uboot.sh` | Clones U-Boot and TF-A (or uses Rockchip's binary BL31), builds the bootloader and SPL loader for each target board |
| `build-kernel-mainline.sh` | Clones `flipper-linux-kernel`, merges config fragments from `configs/linux/`, builds arm64 kernel `.deb` packages and DTBs |
| `build-kernel-bsp.sh` | Clones Rockchip's BSP kernel (`develop-6.1`), fetches vendor DTS files, applies patches from `patches/bsp/`, builds arm64 kernel packages |
| `build-images.sh` | Assembles complete GPT disk images for all boards you've built bootloaders for; calls `build-rootfs-img.sh` to build the root filesystem if it doesn't exist yet |
| `build-rootfs-img.sh` | Runs debos on `debian-rk3576-img.yaml` to install the kernel into a partitioned image, then zeekstd-compresses it |
| `build-ospack.sh` | Runs mmdebstrap via debos (`debian-rk3576-ospack.yaml`) to build the Debian root filesystem tarball |

Other directories:

- `configs/` — kernel config fragments merged on top of the base config (`minconfig-mainline` for mainline, `linux-bsp/` for the BSP kernel)
- `overlays/` — files copied into the root filesystem: systemd units, NetworkManager config, Broadcom Wi-Fi/BT firmware, KDE Plasma settings, SDDM autologin, U-Boot menu config
- `vendor-dts/` — Luckfox Omni3576 DTS/DTSI files and BSP device tree overlay sources (`.dtso`) for the EVB evaluation board and shared peripherals
- `patches/bsp/` — kernel patches applied to the BSP tree (TypeC, panfrost DTS, audio card)
- `rk_unpacker/` — standalone Python tool to extract partition images from Rockchip `update.img` files
- `prebuilt/`, `src/`, `out/` — build outputs and source clones; all gitignored

---

## Automated builds

Every push to this repository (and to the tracked branches of its dependencies) triggers a full build on Buildbot. The resulting images land at [dl-linux-images.flipp.dev/full-img/](https://dl-linux-images.flipp.dev/full-img/) and are updated automatically.

### Supported boards

| Board | Target name | Notes |
|---|---|---|
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/a05325e0-9e03-4a07-b39c-12d618a95469"><br><sub>Flipper One Prototype</sub></div> | `flipper-one` | Our current Flipper One prototype |
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/3f8d7d73-70f3-4c02-a290-6f2f51621499"><br><sub><a href="https://docs.banana-pi.org/en/BPI-M5/BananaPi_BPI-M5_Pro">Banana Pi BPI-M5 Pro</a><br>aka <a href="https://www.armsom.org/sige5">ArmSoM Sige5</a></sub></div> | `sige5` | Same hardware sold under two names. Has DisplayPort on USB-C. Recommended for development. |
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/135c0fca-3dfe-4d33-b239-10184154935c"><br><sub><a href="https://radxa.com/products/rock4/4d/">Radxa ROCK 4D</a></sub></div> | `rock-4d` | No DisplayPort on USB-C. Entering Maskrom requires a USB-A to USB-A cable. Available with eMMC or UFS storage — see [eMMC note below](#flashing-radxa-rock-4d-emmc). |
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/605a8b7f-a85e-4735-8198-81005ed4ec5c"><br><sub><a href="https://www.friendlyelec.com/index.php?route=product/product&product_id=309">FriendlyElec NanoPi M5</a></sub></div> | `nanopi-m5` | Available with optional UFS storage module. UFS module part number differs from Flipper One prototypes, so there may be subtle behavior differences. |
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/b297e6ab-88d8-4085-a0d2-b989462414b1"><br><sub><a href="https://www.luckfox.com/EN-Luckfox-Omni3576">Luckfox Omni3576</a></sub></div> | `omni3576` | |
| <div align="center"><img width="200" src="https://github.com/user-attachments/assets/82d41031-3548-42cb-8a6f-e9037fb76ea3"><br><sub><a href="https://www.firefly.io/products/ROC-RK3576-PC.html">Firefly ROC-RK3576-PC</a></sub></div> | `roc-pc` | |
| Rockchip RK3576 EVB1 | `evb` | Official Rockchip evaluation board. Not available for sale. |

---

## How to build image manually

The scripts are designed to run on Debian 13 (trixie). Other distributions may work but you'll need to find the equivalent packages yourself.

### Quick start with Docker or Podman

Use the included `Dockerfile` to avoid installing anything on the host:

```bash
# Clone the repo
git clone https://github.com/flipperdevices/flipperone-linux-build-scripts
cd flipperone-linux-build-scripts

# Build the container image (one-time; typically 20–30 min depending on network and CPU)
docker build -t flipperone-linux-build-scripts .

# Run a full build — images appear in out/images/
mkdir -p out
docker run --privileged --rm -v "$(pwd)/out:/artifacts" \
    flipperone-linux-build-scripts
```

Replace `docker` with `podman` if that's what you have. `--privileged` is required because debos and mmdebstrap use loop devices and mount namespaces.

### Quick start with VS Code Dev Container

1. Install [VS Code](https://code.visualstudio.com/) and the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
2. Clone this repository and open it in VS Code
3. Press `F1` and select **"Dev Containers: Reopen in Container"**
4. Wait for the container to build (first time only)
5. Run build scripts from the integrated terminal

### Building on a bare Debian 13 host

For the bootloader:

```bash
sudo dpkg --add-architecture arm64
sudo apt update
sudo apt install git build-essential crossbuild-essential-arm64 bison flex \
    python3-dev python3-libfdt python3-setuptools swig libssl-dev gnutls-dev \
    python3-pyelftools device-tree-compiler
```

For the kernel:

```bash
sudo dpkg --add-architecture arm64
sudo apt update
sudo apt install git build-essential crossbuild-essential-arm64 bc bison flex \
    imagemagick libssl-dev libdw-dev libelf-dev debhelper libssl-dev:arm64 rsync
```

For assembling disk images — debos, bmaptool, and zeekstd all need to be installed from source:

```bash
sudo apt install golang pipx pigz cargo parted fdisk btrfs-progs mmdebstrap \
    systemd-resolved systemd-container qemu-user-binfmt \
    libglib2.0-dev libostree-dev fakemachine

# debos
go install -v github.com/go-debos/debos/cmd/debos@latest
sudo install -m 755 ~/go/bin/debos /usr/local/bin

# zeekstd (requires Rust; v0.4.5+ needs Rust 1.91 — stick to v0.4.4-cli for now)
cargo install --git https://github.com/rorosen/zeekstd.git --tag v0.4.4-cli zeekstd_cli
sudo install -m 755 ~/.cargo/bin/zeekstd /usr/local/bin/

# bmaptool (Flipper fork)
sudo pipx install --global git+https://github.com/flipperdevices/bmaptool.git@flipper-devel
```

For flashing images to boards over USB:

```bash
sudo apt install rockusb
```

### Building the bootloader

To fetch and build U-Boot with open-source TF-A:

```bash
./build-uboot.sh
```

The default source is the Flipper fork of U-Boot (`flipperdevices/u-boot`, branch `rk3576`), which has defconfigs for all supported boards. Upstream U-Boot now supports most boards listed here — NanoPi M5, NanoPi R76S, Luckfox Omni3576, ArmSoM Sige5, Firefly ROC-RK3576-PC, and Radxa Rock 4D. The Flipper fork is needed for Flipper One and EVB1.

To build for a specific board instead of all boards:

```bash
BOARD=sige5 ./build-uboot.sh
```

If you need a different U-Boot source tree (e.g., a newer upstream tree for a specific board):

```bash
BOARD=sige5 UBOOT_GIT="https://source.denx.de/u-boot/contributors/kwiboo/u-boot.git" UBOOT_BRANCH="rk3576" ./build-uboot.sh
BOARD=omni3576 KEEP_SRC=yes ./build-uboot.sh
BOARD=nanopi-m5 KEEP_SRC=yes ./build-uboot.sh
BOARD=rock-4d KEEP_SRC=yes ./build-uboot.sh
```

`KEEP_SRC=yes` reuses the already-cloned source tree; `KEEP_SRC=update` pulls the latest commits without a full re-clone.

To use Rockchip's binary BL31 instead of open-source TF-A:

```bash
USE_BL31=vendor BOARD=sige5 UBOOT_GIT="https://source.denx.de/u-boot/contributors/kwiboo/u-boot.git" UBOOT_BRANCH="rk3576" ./build-uboot.sh
USE_BL31=vendor BOARD=omni3576 KEEP_SRC=yes ./build-uboot.sh
USE_BL31=vendor BOARD=nanopi-m5 KEEP_SRC=yes ./build-uboot.sh
USE_BL31=vendor BOARD=rock-4d KEEP_SRC=yes ./build-uboot.sh
```

Outputs go to `prebuilt/u-boot/<board>/` — `u-boot-rockchip.bin`, `rk3576_loader_v*.bin`, and `rk3576_loader_fspi1_v*.bin` per board, plus USB loader variants.

### Building the kernel

#### Mainline kernel

```bash
./build-kernel-mainline.sh
```

To rebuild without re-downloading:

```bash
KEEP_SRC=yes ./build-kernel-mainline.sh
```

To incrementally pull new commits without a full fresh clone:

```bash
KEEP_SRC=update ./build-kernel-mainline.sh
```

To build from a different tree:

```bash
LINUX_GIT=https://gitlab.collabora.com/hardware-enablement/rockchip-3588/linux.git \
    LINUX_BRANCH=rockchip-devel ./build-kernel-mainline.sh
```

#### BSP kernel

```bash
./build-kernel-bsp.sh
```

The same `KEEP_SRC` variants work here too.

### Assembling disk images

Once you have bootloader outputs in `prebuilt/u-boot/` and kernel outputs in `prebuilt/linux/`, run:

```bash
./build-images.sh
```

This produces compressed images for each board whose bootloader is present. The kernel and root filesystem are shared; only the bootloader partition differs per board. Output files: `out/debian-<sector-size>-<board>-<timestamp>.img.gz` with a matching `.bmap` file, for both 512-byte and 4096-byte sector variants. When run inside the container, images go to `out/images/` instead (the container sets `IMG_OUT=/artifacts/images`).

Don't run the mainline and BSP kernel scripts in parallel against the same output directory — both write to the same `prebuilt/linux/` path and the final packaging step will fail. Run one, then the other (or set separate `LINUX_OUT` paths).

### Writing the image to SD/eMMC

#### Flashing to an SD card

To produce a bootable SD card with your newly built Debian image, connect it to your host computer (e.g. through a card reader).

If you have a built-in SD card slot, you may use that, and the card will likely show up as `/dev/mmcblkX` (where `X` is the number identifying the respective SD/MMC controller, likely `0` if you only have one).

If you are using a USB card reader, the card will likely show up as `/dev/sdX` (where `X` is a lowercase letter). In this latter case you need to be triple careful, because any SATA or SCSI storage devices will also share the same naming scheme, and if you have important data on any other `/dev/sdX` device (such as your main system disk being called something like `/dev/sda`) you might end up inadvertently overwriting it if you pick the wrong one in the below commands, losing all your data. Please be careful.

```bash
sudo bmaptool copy out/debian-512-<your_board>-*.img.gz /dev/sdX
```

#### Flashing to eMMC using a USB cable and Maskrom

Rockchip devices include a special built-in mode called Maskrom, which allows flashing the board over a USB connection even if the board contains no bootloader or it is corrupted.

This mode is activated by holding down a MASKROM button when the power supply gets connected.

- Instructions for [Radxa Rock 4D](https://docs.radxa.com/en/rock4/rock4d/hardware-use/maskrom?maskrom-display=Linux%2FMacOS): Connect a USB A to A cable (or Type C to USB A, depending on your host computer's available USB ports) to the top USB 3.0 blue port, hold the MASKROM button and apply power to the board as usual via its Type C DC IN. Note that eMMC modules cannot be used together with the onboard SPI flash, as they share pins internally
- Instructions for [ArmSoM Sige5](https://docs.armsom.org/getting-start/flash-img#241-device-connection): Connect a USB A to Type C cable (or Type C to Type C, depending on your host computer's available USB ports) to the Type C OTG port (marked TYPEC on the board), hold the MASKROM button and apply power to the board as usual via its Type C DC IN

You should then see something like this in `lsusb` command output:

```
Bus 002 Device 011: ID 2207:350e Fuzhou Rockchip Electronics Company
```

Your device is now ready for programming over the Rockusb protocol.

```bash
# Boot the board in USB upload mode
sudo rockusb download-boot prebuilt/u-boot/<your_board>/rk3576_loader_v*.bin

sudo rockusb write-bmap out/debian-512-<your_board>-*.img.gz
```

Container builds place bootloaders in `out/u-boot/<board>/` and disk images in `out/images/` instead.

##### Flashing Radxa Rock 4D eMMC

The Rock 4D's eMMC and FSPI0 (SPI flash) share the same pins — only one can be active at a time. Upstream DTS enables FSPI0 by default, so images built without further modification will not work with eMMC storage on this board. If you need eMMC, make sure the device tree enables the eMMC controller and disables FSPI0. UFS storage does not have this restriction.

Switch Radxa 4D into Maskrom mode, then:

```bash
rockusb list
rockusb download-boot prebuilt/u-boot/rock-4d/rk3576_loader_v*.bin
rockusb write-bmap out/debian-512-rock-4d-*.img.gz
rockusb reset-device
```

---

## How to contribute

### Branch model

Push access to this repository is limited to Flipper developers. To contribute, fork the repository first, then work on a branch in your fork and open a PR from there to `dev` in the main repo:

```bash
# Fork on GitHub, then clone your fork
git clone https://github.com/<your-username>/flipperone-linux-build-scripts
cd flipperone-linux-build-scripts
git remote add upstream https://github.com/flipperdevices/flipperone-linux-build-scripts

# Keep your fork's dev up to date
git fetch upstream && git checkout dev && git merge upstream/dev

# Branch and push to your fork
git checkout -b your-feature-name
# make changes, then:
git push origin your-feature-name
```

Open a PR from `<your-username>/flipperone-linux-build-scripts:your-feature-name` to `flipperdevices/flipperone-linux-build-scripts:dev`.

### CI

Every PR and every push to `dev` triggers a full build on Buildbot — all boards, both kernels. The green checkmark on a commit means they all passed. If your PR makes the build go red, it won't merge.

To test locally before pushing:

```bash
docker build -t flipperone-linux-build-scripts .
mkdir -p out
docker run --privileged --rm -v "$(pwd)/out:/artifacts" flipperone-linux-build-scripts
```

### Adding kernel config options

Drop a config fragment file in `configs/linux/` (mainline) or `configs/linux-bsp/` (BSP). Every file in those directories gets merged in. One file per logical feature.

### Modifying the root filesystem

Files go in `overlays/`, mirroring the target filesystem: `overlays/configs/` → `/etc/`, `overlays/usr/` → `/usr/`, etc. Firmware blobs go in `overlays/firmware/`. For system packages, edit `debian-rk3576-ospack.yaml`.

### Adding a new board

Adding a board properly means getting it upstream in Linux first, then in U-Boot. BL31 is not board-specific and doesn't need to be touched.

The rough sequence:

1. **Linux device tree bindings**: Add a vendor prefix binding to upstream Linux (if the vendor isn't already there), a compatible binding for the board, and bindings for any board-specific devices not yet upstream.
2. **Linux drivers**: Add drivers for any board-specific devices not yet upstream.
3. **Linux DTS**: Add the board DTS to upstream Linux and get it merged to master.
4. **U-Boot defconfig**: Once the DTS is in Linux master (pulled into U-Boot via `dts/upstream`), add a defconfig for the board in the Flipper U-Boot fork. If the DTS is in linux-next but not yet in master, a temporary `[HACK]` commit can import it directly into the Flipper dev branch — but that commit must be dropped before submitting upstream.
5. **Kernel config fragment**: Add any board-specific kernel options as a fragment in `configs/linux/`.
6. **Device tree (BSP kernel, if needed)**: Vendor DTS files go in `vendor-dts/` (see `vendor-dts/omni3576/` for the layout). Device tree overlays go in `vendor-dts/bsp/` as `.dtso` files.

Open a PR with a description of the board and how you tested that the image boots.
