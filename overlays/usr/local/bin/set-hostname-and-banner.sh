#!/bin/sh
set -e

# Extract board name from device tree
board=$(cat /sys/firmware/devicetree/base/compatible | tr '\0' '\n' | awk -F, '$2 != "rk3576" { print $2; exit }')
board=${board:-rk3576}

# CPU serial from device tree, falls back to systemd machine-id for non-DT boards
serial=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || cat /etc/machine-id)

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
CPU Serial:   $serial
Memory:       $total_mem
Build Date:   $build_date
Default credentials: user / user
=============================================================
EOF

# Generate Avahi mDNS service for LAN discovery via _flipper._tcp
mkdir -p /etc/avahi/services
cat <<EOF >/etc/avahi/services/flipper.service
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service>
    <type>_flipper._tcp</type>
    <port>22</port>
    <txt-record>serial=${serial}</txt-record>
  </service>
</service-group>
EOF

systemd-machine-id-setup
