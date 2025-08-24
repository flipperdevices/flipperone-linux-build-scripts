FROM debian:trixie

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Update sources to include contrib, non-free, and non-free-firmware
RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources

# Update and upgrade base system
RUN apt-get update && apt-get upgrade -y

# Add arm64 architecture for cross-compilation
RUN dpkg --add-architecture arm64 && apt-get update

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
    libdw-dev \
    libelf-dev \
    debhelper \
    libssl-dev:arm64 \
    rsync

# Prerequisites for fetching vendor DTS files (if using a Rockchip BSP kernel)
RUN apt-get install -y \
    wget \
    repo

# Prerequisites for assembling complete disk images
RUN apt-get install -y \
    debos \
    mmdebstrap \
    systemd-resolved \
    bmap-tools \
    pigz

# Prerequisites for uploading images over USB
RUN apt-get install -y \
    rockusb

# Clone the rk3576-linux-build repository
WORKDIR /rk3576-linux-build
RUN git clone https://github.com/flipperdevices/rk3576-linux-build .

# Clean up apt cache to reduce image size
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /rk3576-linux-build

# Entry point
CMD ["/bin/bash"]

