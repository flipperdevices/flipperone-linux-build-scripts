FROM debian:trixie

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV IMG_OUT=/artifacts/images
ENV UBOOT_OUT=/artifacts/u-boot
ENV LINUX_OUT=/artifacts/linux

# Add arm64 architecture for cross-compilation
RUN dpkg --add-architecture arm64 && apt-get update

# Upgrade base system
RUN apt-get upgrade -y

# Prerequisites
RUN apt-get install -y \
    git \
    build-essential \
    crossbuild-essential-arm64 \
    bison \
    flex \
    parted \
    fdisk \
    btrfs-progs \
    python3-dev \
    python3-libfdt \
    python3-setuptools \
    swig \
    libssl-dev \
    gnutls-dev \
    python3-pyelftools \
    qemu-user-binfmt \
    bc \
    imagemagick \
    libdw-dev \
    libelf-dev \
    debhelper \
    device-tree-compiler \
    libssl-dev:arm64 \
    rsync \
    wget \
    mmdebstrap \
    systemd-container \
    systemd-resolved \
    pipx \
    pigz \
    zstd \
    golang \
    libglib2.0-dev \
    libostree-dev \
    fakemachine

# Rust for zeekstd below and for flipctl during the ospack build, from backports rather
# than trixie: slint 1.17.1 wants rustc 1.92 and trixie has 1.85. libstd-rust-dev:arm64
# is the standard library for the target, which is what lets build-flipctl.sh cross-build
# on an amd64 builder.
RUN echo 'deb http://deb.debian.org/debian trixie-backports main' \
        > /etc/apt/sources.list.d/backports.list \
    && apt-get update \
    && apt-get install -y -t trixie-backports \
        cargo rustc libstd-rust-dev libstd-rust-dev:arm64

RUN go install -v github.com/go-debos/debos/cmd/debos@latest

RUN install -m 755 ~/go/bin/debos /usr/local/bin

RUN cargo install --git https://github.com/rorosen/zeekstd.git zeekstd_cli

RUN install -m 755 ~/.cargo/bin/zeekstd /usr/local/bin/

RUN pipx install --global git+https://github.com/flipperdevices/bmaptool.git@flipper-devel

# Clean up apt cache to reduce image size
RUN apt-get clean && rm -rf /var/lib/apt/lists/* ~/.cargo ~/go

# Clone the flipperone-linux-build-scripts repository
WORKDIR /flipperone-linux-build-scripts
RUN git clone --depth=1 https://github.com/flipperdevices/flipperone-linux-build-scripts .

# Entry point
ENTRYPOINT ./build-uboot.sh && ./build-kernel-mainline.sh && ./build-kernel-bsp.sh && ./build-images.sh
