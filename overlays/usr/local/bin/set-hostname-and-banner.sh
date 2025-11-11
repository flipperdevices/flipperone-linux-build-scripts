#!/bin/sh
set -e

# Extract board name from device tree
board=$(cat /sys/firmware/devicetree/base/compatible | tr '\0' '\n' | awk -F, '$2 != "rk3576" { print $2; exit }')
board=${board:-rk3576}

codename=$(. /etc/os-release; echo "${ID}${VERSION_ID}-${BUILD_ID}")
new_hostname="${board}-${codename}"

hostnamectl set-hostname "${new_hostname}"

. /etc/os-release

# Get build info
build_id=${BUILD_ID:-0}
build_git=${BUILD_GIT:-unknown}
build_date=$(date -d "@$build_id" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo "$build_id")

total_mem=$(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo)

# Generate SSH welcome banner
cat <<EOF >/etc/ssh/welcome_banner
=================== Welcome to FlipperOne ===================
Git:          $build_git
Board:        $board
Memory:       $total_mem
Build Date:   $build_date
Default credentials: user / user
=============================================================
EOF

systemd-machine-id-setup
