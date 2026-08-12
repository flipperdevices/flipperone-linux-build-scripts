#!/bin/bash
: "${IMG_OUT:=out}"
: "${TESTS_DIR:=src/tests}"
: "${KEEP_SRC:=no}"
: "${TESTS_OUT:=prebuilt/tests}"
: "${TESTS_GIT:=https://github.com/flipperdevices/rk3576-linux-tests.git}"
: "${TESTS_BRANCH:=dev}"
: "${BTRFS_TOOLS_DIR:=src/btrfs-tools}"
: "${BTRFS_TOOLS_OUT:=prebuilt/btrfs-tools}"
: "${BTRFS_TOOLS_GIT:=https://github.com/flipperdevices/flipperos-btrfs-tools.git}"
: "${BTRFS_TOOLS_BRANCH:=dev}"

set -e

# Capture Git information
[ -n "${GIT_HASH}" ] || GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
[ -n "${GIT_BRANCH}" ] || GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || echo "detached")
[ -n "${GIT_MSG}" ] || GIT_MSG=$(git log -1 --pretty=format:"%s" 2>/dev/null | sed 's/[\"()]/\\&/g; s/'"'"'/\\&/g' || echo "unknown")
[ -n "${GIT_INFO}" ] || GIT_INFO="${GIT_BRANCH}@${GIT_HASH}: ${GIT_MSG}"
GIT_INFO=$(echo "$GIT_INFO" | tr -dc '[:alnum:][:space:]')

stage_repo() { # $1 = checkout  $2 = url  $3 = branch  $4 = staging dir
        case "${KEEP_SRC}" in
                update)
                        if [ -d "$1" ]; then
                                git -C "$1" pull
                        fi
                        ;;
                no)
                        rm -rf "$1"
                        ;;
                *)
                        ;;
        esac

        [ -d "$1" ] || git clone --depth 1 -b "$3" "$2" "$1"

        rm -rf "$4"
        mkdir -p "$4"
        cp -a "$1/." "$4/"
}

mkdir -p "$IMG_OUT"

stage_repo "${TESTS_DIR}" "${TESTS_GIT}" "${TESTS_BRANCH}" "${TESTS_OUT}"
stage_repo "${BTRFS_TOOLS_DIR}" "${BTRFS_TOOLS_GIT}" "${BTRFS_TOOLS_BRANCH}" "${BTRFS_TOOLS_OUT}"

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

$DEBOS --artifactdir="$IMG_OUT" -t gitinfo:"$GIT_INFO" -t testsdir:"${TESTS_OUT}" -t btrfstoolsdir:"${BTRFS_TOOLS_OUT}" debian-rk3576-ospack.yaml
