#!/bin/bash
: "${IMG_OUT:=out}"
: "${TESTS_DIR:=src/tests}"
: "${KEEP_SRC:=no}"
: "${TESTS_OUT:=prebuilt/tests}"
: "${TESTS_GIT:=https://github.com/flipperdevices/rk3576-linux-tests.git}"
: "${TESTS_BRANCH:=dev}"

set -e

# Capture Git information
[ -n "${GIT_HASH}" ] || GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
[ -n "${GIT_BRANCH}" ] || GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || echo "detached")
[ -n "${GIT_MSG}" ] || GIT_MSG=$(git log -1 --pretty=format:"%s" 2>/dev/null | sed 's/[\"()]/\\&/g; s/'"'"'/\\&/g' || echo "unknown")
[ -n "${GIT_INFO}" ] || GIT_INFO="${GIT_BRANCH}@${GIT_HASH}: ${GIT_MSG}"

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

cp -r "${TESTS_DIR}"/* "${TESTS_OUT}/"

if [ -c /dev/kvm -a -w /dev/kvm ]; then
        # Have virtualization support, can use fakemachine (default, fast, safe)
        DEBOS="debos -c $(nproc) -m 6Gb"
elif [ -f /.dockerenv ]; then
        # Running in a container without access to virtualization, fall back to the slow method
        DEBOS="debos -b qemu -c $(nproc) -m 6Gb"
elif [ `id -u` -eq 0 ]; then
        # Running as root, can use the host mode without fakemachine (fast, less safe)
        DEBOS="debos"
else
        DEBOS="sudo debos --disable-fakemachine"
fi

$DEBOS --artifactdir="$IMG_OUT" -t gitinfo:"$GIT_INFO" -t testsdir:"${TESTS_OUT}" debian-rk3576-ospack.yaml
