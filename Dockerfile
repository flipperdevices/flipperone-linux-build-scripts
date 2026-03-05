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

# Prerequisites for building the bootloader
RUN apt-get install -y \
    git \
    build-essential \
    crossbuild-essential-arm64 \
    bison \
    flex \
    python3-dev \
    python3-libfdt \
    python3-setuptools \
    swig \
    libssl-dev \
    gnutls-dev \
    python3-pyelftools

# Prerequisites for building the kernel
RUN apt-get install -y \
    bc \
    imagemagick \
    libdw-dev \
    libelf-dev \
    debhelper \
    device-tree-compiler \
    libssl-dev:arm64 \
    rsync

# Prerequisites for fetching vendor DTS files (if using a Rockchip BSP kernel)
RUN apt-get install -y \
    wget

# Prerequisites for assembling complete disk images
RUN apt-get install -y \
    mmdebstrap \
    systemd-resolved \
    bmap-tools \
    pigz \
    cargo \
    golang \
    libglib2.0-dev \
    libostree-dev \
    fakemachine

RUN go install -v github.com/go-debos/debos/cmd/debos@latest

RUN install -m 755 ~/go/bin/debos /usr/local/bin

RUN cargo install --git https://github.com/rorosen/zeekstd.git zeekstd_cli

RUN install -m 755 ~/.cargo/bin/zeekstd /usr/local/bin/

# Clean up apt cache to reduce image size
RUN apt-get clean && rm -rf /var/lib/apt/lists/* ~/.cargo ~/go

# Clone the rk3576-linux-build repository
WORKDIR /rk3576-linux-build
RUN git clone --depth=1 https://github.com/flipperdevices/rk3576-linux-build .

# Entry point
ENTRYPOINT ./build-uboot.sh && ./build-kernel-mainline.sh && ./build-kernel-bsp.sh && ./build-images.sh
