FROM debian:trixie AS toolchain

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

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
    cargo \
    golang \
    libglib2.0-dev \
    libostree-dev \
    fakemachine

RUN go install -v github.com/go-debos/debos/cmd/debos@latest

RUN install -m 755 ~/go/bin/debos /usr/local/bin

# v0.4.5-cli+ needs Rust 1.91 (Path::with_added_extension); see https://github.com/rorosen/zeekstd/tags
RUN cargo install --git https://github.com/rorosen/zeekstd.git --tag v0.4.4-cli zeekstd_cli

RUN install -m 755 ~/.cargo/bin/zeekstd /usr/local/bin/

RUN pipx install --global git+https://github.com/flipperdevices/bmaptool.git@flipper-devel

# Clean up apt cache to reduce image size
RUN apt-get clean && rm -rf /var/lib/apt/lists/* ~/.cargo ~/go

FROM toolchain AS build

ENV IMG_OUT=/artifacts/images
ENV UBOOT_OUT=/artifacts/u-boot
ENV LINUX_OUT=/artifacts/linux

WORKDIR /flipperone-linux-build-scripts
COPY . .

RUN bash -n docker-entrypoint.sh \
    && install -m 755 docker-entrypoint.sh /usr/local/bin/flipperone-entrypoint

ENTRYPOINT ["/usr/local/bin/flipperone-entrypoint"]
