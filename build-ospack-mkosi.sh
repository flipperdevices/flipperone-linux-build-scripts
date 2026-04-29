#!/bin/bash
: "${IMG_OUT:=out}"
: "${TESTS_DIR:=src/tests}"
: "${KEEP_SRC:=no}"
: "${TESTS_OUT:=prebuilt/tests}"
: "${TESTS_GIT:=https://github.com/flipperdevices/rk3576-linux-tests.git}"
: "${TESTS_BRANCH:=dev}"

set -e

if ! command -v mkosi >/dev/null 2>&1; then
    echo "mkosi is not installed or not in PATH"
    exit 1
fi

[ -n "${GIT_HASH}" ] || GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
[ -n "${GIT_BRANCH}" ] || GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || echo "detached")
[ -n "${GIT_MSG}" ] || GIT_MSG=$(git log -1 --pretty=format:"%s" 2>/dev/null | sed 's/[\"()]/\\&/g; s/'"'"'/\\&/g' || echo "unknown")
[ -n "${GIT_INFO}" ] || GIT_INFO="${GIT_BRANCH}@${GIT_HASH}: ${GIT_MSG}"
GIT_INFO=$(echo "$GIT_INFO" | tr -dc '[:alnum:][:space:]')

case "${KEEP_SRC}" in
    update)
        git -C "${TESTS_DIR}" pull
        ;;
    no)
        rm -rf "${TESTS_DIR}"
        ;;
    *)
        ;;
esac

[ -d "${TESTS_DIR}" ] || git clone --depth 1 -b "${TESTS_BRANCH}" "${TESTS_GIT}" "${TESTS_DIR}"

mkdir -p "$IMG_OUT"
rm -rf "${TESTS_OUT}"
mkdir -p "${TESTS_OUT}"
cp -a "${TESTS_DIR}/." "${TESTS_OUT}/"

# Download sbc-bench on the host (mkosi chroot has no network access)
SBC_BENCH_DIR="${IMG_OUT}/mkosi-sbc-bench"
mkdir -p "${SBC_BENCH_DIR}/usr/bin"
wget -O "${SBC_BENCH_DIR}/usr/bin/sbc-bench.sh" \
    https://raw.githubusercontent.com/ThomasKaiser/sbc-bench/master/sbc-bench.sh
chmod +x "${SBC_BENCH_DIR}/usr/bin/sbc-bench.sh"

mkosi \
    -C mkosi/ospack \
    --force \
    --output-directory "$(realpath "$IMG_OUT")" \
    --environment "GIT_INFO=${GIT_INFO}" \
    --sandbox-tree "$(realpath overlays/configs/apt):/etc/apt" \
    --extra-tree "$(realpath overlays/configs):/etc" \
    --extra-tree "$(realpath overlays/firmware):/usr/lib/firmware" \
    --extra-tree "$(realpath overlays/usr/local):/usr/local" \
    --extra-tree "$(realpath overlays/usr/sbin):/usr/sbin" \
    --extra-tree "$(realpath overlays/usr/share):/usr/share" \
    --extra-tree "$(realpath "${TESTS_OUT}"):/flipperone-testing" \
    --extra-tree "$(realpath "${SBC_BENCH_DIR}"):/" \
    build

if [ -f "$IMG_OUT/debian-ospack.tar" ]; then
    pigz -f -n "$IMG_OUT/debian-ospack.tar"
fi

if [ ! -f "$IMG_OUT/debian-ospack.tar.gz" ]; then
    echo "mkosi ospack artifact was not produced"
    exit 1
fi
