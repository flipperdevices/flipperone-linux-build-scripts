#!/bin/bash
# build-flipctl.sh [<checkout> [<staging dir>]] - build flipctl for the image.
#
# Stages the tree the ospack overlays onto /usr: bin/flipctl, its apps and remote-view
# assets under share/flipctl, and the unit the repository ships as
# lib/systemd/system/flipctl.service. Called by build-ospack.sh once it has the checkout.
#
# Native on an arm64 builder, cross anywhere else. Nothing here links a C library (EGL
# and GBM are dlopened, wayland-client uses its Rust backend, slint renders in software),
# so a cross build needs the aarch64 std and a linker and nothing else.
: "${FLIPCTL_DIR:=src/flipctl}"
: "${FLIPCTL_OUT:=prebuilt/flipctl}"
: "${FLIPCTL_FEATURES:=device,slint,remote,wayland,gpu}"

set -e

SRC=${1:-$FLIPCTL_DIR}
OUT=${2:-$FLIPCTL_OUT}
PKG=flipctl

[ -d "$SRC" ] || { echo "build-flipctl: no checkout at $SRC" >&2; exit 1; }
command -v cargo >/dev/null || { echo "build-flipctl: cargo not found" >&2; exit 1; }

# slint 1.17.1 sets the floor. An older cargo gets there through the resolver instead,
# a hundred lines of "requires rustc" for every crate in the graph, so check it here.
MSRV=92
ver=$(cargo --version 2>/dev/null | awk '{print $2}')
case "$ver" in 1.*) minor=${ver#1.}; minor=${minor%%.*} ;; *) minor=0 ;; esac
case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
if [ "$minor" -lt "$MSRV" ]; then
        echo "build-flipctl: cargo ${ver:-unknown} is too old; flipctl needs 1.$MSRV (slint 1.17.1)" >&2
        echo "build-flipctl: on Debian, apt-get install -t trixie-backports cargo rustc libstd-rust-dev" >&2
        exit 1
fi

# Cross unless the builder is already arm64. Passing --target on an arm64 builder too
# would flatten this, at the cost of cargo building every proc macro and build script for
# the host separately from the target, which is the slint compiler twice over.
TARGET_ARG=()
if [ "$(uname -m)" != aarch64 ]; then
        TARGET=aarch64-unknown-linux-gnu
        TARGET_ARG=(--target "$TARGET")
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
        # a toolchain carries the host's standard library and no other, and without the
        # target's the build fails a long way in with "can't find crate for std"
        [ -d "$(rustc --print sysroot)/lib/rustlib/$TARGET" ] || {
                echo "build-flipctl: no std for $TARGET" >&2
                echo "build-flipctl: on Debian, apt-get install libstd-rust-dev:arm64" >&2
                exit 1
        }
fi

# cargo install builds and places the binary in one step, and --root makes the staging
# tree what it installs into: bin/flipctl, already the install layout, so the ospack
# overlays it and moves nothing afterwards. --no-track keeps the .crates.toml it would
# leave beside it out of a tree that becomes /usr, --target-dir keeps the build cache in
# the checkout rather than the temporary directory cargo install builds in and throws
# away, and --locked pins what cargo build would: this is the one cargo command that
# ignores a lockfile unless told not to.
rm -rf "$OUT"
cargo install --path "$SRC/bin/$PKG" --root "$OUT" --no-track --locked \
        --target-dir "$SRC/target" "${TARGET_ARG[@]}" --features "$FLIPCTL_FEATURES"
mkdir -p "$OUT/share/flipctl"
# An app's build output and its uv environment sit inside the app's own directory, and
# a checkout kept between runs (KEEP_SRC) still has them.
tar -C "$SRC" -cf - --exclude=.venv --exclude=target --exclude=__pycache__ apps \
        | tar -C "$OUT/share/flipctl" -xf -
mkdir -p "$OUT/share/flipctl/assets"
cp -a "$SRC/crates/flipper-ui/assets/remote" "$OUT/share/flipctl/assets/remote"
# The unit ships from the repository, not a copy in overlays/, so a deploy from a
# checkout restarts the same unit the image boots.
install -D -m 644 "$SRC/systemd/flipctl.service" "$OUT/lib/systemd/system/flipctl.service"

echo "build-flipctl: staged $(du -sh "$OUT" | cut -f1) in $OUT"
