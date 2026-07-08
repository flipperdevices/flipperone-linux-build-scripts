FROM debian:trixie@sha256:d07d1b51c39f51188e60be9b64e6bf769fa94e187f092bc32b91305cfa34ba5a

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV IMG_OUT=/artifacts/images
ENV UBOOT_OUT=/artifacts/u-boot
ENV LINUX_OUT=/artifacts/linux

# Add arm64 architecture for cross-compilation
RUN dpkg --add-architecture arm64 && apt-get update

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

# ponytail: pinned to v1.1.7 — upstream is transitioning subvolume creation support
# (go-debos/debos#736/62cb992). Re-pin once the transition settles.
RUN go install -v github.com/go-debos/debos/cmd/debos@v1.1.7

RUN install -m 755 ~/go/bin/debos /usr/local/bin

# v0.4.5-cli+ needs Rust 1.91 (Path::with_added_extension); see https://github.com/rorosen/zeekstd/tags
RUN cargo install --git https://github.com/rorosen/zeekstd.git --tag v0.4.4-cli zeekstd_cli

RUN install -m 755 ~/.cargo/bin/zeekstd /usr/local/bin/

RUN pipx install --global git+https://github.com/flipperdevices/bmaptool.git@flipper-devel

# Clean up apt cache to reduce image size
RUN apt-get clean && rm -rf /var/lib/apt/lists/* ~/.cargo ~/go

# Clone the flipperone-linux-build-scripts repository
WORKDIR /flipperone-linux-build-scripts
RUN git clone --depth=1 https://github.com/flipperdevices/flipperone-linux-build-scripts .

# Entry point — exec-form ENTRYPOINT with entrypoint.sh replaces the old
# shell-form `ENTRYPOINT ./build-*.sh && ./build-*.sh && ...` inline chain.
# COPY is required because Docker build context is the repo root; the script
# gets injected into the WORKDIR alongside the cloned sources.
COPY entrypoint.sh /flipperone-linux-build-scripts/entrypoint.sh
RUN chmod +x /flipperone-linux-build-scripts/entrypoint.sh
ENTRYPOINT ["/bin/bash", "/flipperone-linux-build-scripts/entrypoint.sh"]
CMD ["all"]
