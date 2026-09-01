#!/bin/sh
set -e

# Extract board compatible entry (skip SoC entries)
compat=$(cat /sys/firmware/devicetree/base/compatible | tr '\0' '\n' | awk -F, '$2 != "rk3576" { print; exit }')

# Full board name for banner (part after comma, e.g. "one-rev-f0b0c1")
board=$(echo "$compat" | awk -F, '{print $2}')
board=${board:-rk3576}

# Device name for hostname: vendor+product without revision (e.g. "flipperone")
device=$(echo "$compat" | sed 's/-rev-.*//; s/,//')
device=${device:-rk3576}

# The serial from the device tree if the bootloader put it there, else recomputed from the OTP
# the way U-Boot computes serial#, else the machine-id. Tested rather than read blind: the
# redirection fails before the 2>/dev/null beside it can catch anything.
if [ -r /sys/firmware/devicetree/base/serial-number ]; then
    serial=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number)
else
    serial=$(/usr/local/bin/rk3576_cpu_serial.sh 2>/dev/null | awk -F'\t' '/^serial:/{print $2}')
fi
serial=${serial:-$(cat /etc/machine-id)}

# First 3 bytes (6 hex chars) of serial for hostname
serial_prefix=$(printf '%.6s' "$serial")

. /etc/os-release

new_hostname="${device}-${serial_prefix}-${BUILD_ID}"

hostnamectl set-hostname "${new_hostname}"

# Get build info
build_id=${BUILD_ID:-unknown}
build_git=${BUILD_GIT:-unknown}

total_mem=$(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo)

# Get currently booted profile = the btrfs subvolume mounted as root (@Desktop, @Router, @TV-Media-Box, @Minimal).
profile=$(findmnt -nro FSROOT / 2>/dev/null)
profile=${profile#/}
[ -n "$profile" ] && [ "$profile" != "/" ] || profile=unknown

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

# Set WiFi AP SSID with CPU serial in NetworkManager connection profiles
sed -i "s/WIFISSIDSERIAL/${serial}/" /etc/NetworkManager/system-connections/wifi-router*.nmconnection 2>/dev/null || true
nmcli connection reload 2>/dev/null || true

systemd-machine-id-setup

# On disk before the marker exists: a reset here leaves committed inodes with no contents, and the
# banner appearing first would mean a hostname, machine-id or avahi service that never landed.
sync

# The SSH welcome banner, written last on purpose: the unit keys its retry off this file, so it
# must not appear until everything above it is done.
cat <<EOF >/etc/ssh/welcome_banner
=================== Welcome to FlipperOne ===================
Git:          $build_git
Board:        $board
CPU Serial:   $serial
Memory:       $total_mem
Build ID:     $build_id
Profile:      $profile
Default credentials: user / user
=============================================================
EOF

sync
