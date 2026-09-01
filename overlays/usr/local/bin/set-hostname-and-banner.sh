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

# CPU serial from device tree, falls back to systemd machine-id for non-DT boards
serial=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || rk3576_cpu_serial.sh | tail -n1 | awk -F"\t" '{ print $2; }' || cat /etc/machine-id)

# Unique device name derived from the OTP CPU ID, e.g. "Poperik"
name=$(flipper-name.sh "$serial")
name_lc=$(echo "$name" | tr 'A-Z' 'a-z')

. /etc/os-release

# e.g. "flipperone-poperik". BUILD_ID is deliberately not part of the hostname:
# this is what shows up as the DHCP hostname and in mDNS, so it has to stay stable
# across upgrades. The build id is still in the banner, the MOTD and os-release.
new_hostname="${device}-${name_lc}"

hostnamectl set-hostname "${new_hostname}"

# PRETTY_HOSTNAME in /etc/machine-info. BlueZ's hostname plugin picks this up as the
# Bluetooth adapter name, so the device advertises "Flipper One Poperik" over BT too
# (see the note in /etc/bluetooth/main.conf).
hostnamectl --pretty set-hostname "Flipper One ${name}"

# Get build info
build_id=${BUILD_ID:-unknown}
build_git=${BUILD_GIT:-unknown}

total_mem=$(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo)

# Get currently booted profile = the btrfs subvolume mounted as root (@Desktop, @Router, @TV-Media-Box, @Minimal).
profile=$(findmnt -nro FSROOT / 2>/dev/null)
profile=${profile#/}
[ -n "$profile" ] && [ "$profile" != "/" ] || profile=unknown

# Generate SSH welcome banner
cat <<EOF >/etc/ssh/welcome_banner
=================== Welcome to FlipperOne ===================
Name:         $name
Git:          $build_git
Board:        $board
CPU Serial:   $serial
Memory:       $total_mem
Build ID:     $build_id
Profile:      $profile
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
    <txt-record>name=${name}</txt-record>
    <txt-record>serial=${serial}</txt-record>
  </service>
</service-group>
EOF

# Set WiFi AP SSID with the device name in NetworkManager connection profiles
sed -i "s/WIFISSIDNAME/${name}/" /etc/NetworkManager/system-connections/wifi-router*.nmconnection 2>/dev/null || true
nmcli connection reload 2>/dev/null || true

systemd-machine-id-setup
