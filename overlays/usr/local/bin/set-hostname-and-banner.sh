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

# The name fused into the MCU at the factory, if the MCU reports one (empty on other boards)
name=$(/usr/local/bin/flipper-one-name.sh) || name=

# The name the way a hostname label takes it ("P00per" -> "flipperone-p00per"), else the first
# 3 bytes (6 hex chars) of the serial
host_suffix=$(printf '%s' "$name" | tr 'A-Z._' 'a-z--' | sed 's/^-*//; s/-*$//')
[ -n "$host_suffix" ] || host_suffix=$(printf '%.6s' "$serial")

. /etc/os-release

new_hostname="${device}-${host_suffix}"

hostnamectl set-hostname "${new_hostname}"

# BlueZ names the Bluetooth adapter after the pretty hostname, which the call above clears.
# Not worth stopping for: the hostname is already set, so nothing below would get another run.
if [ -n "$name" ]; then
    hostnamectl set-hostname --pretty "Flipper One ${name}" || true
fi

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
    <txt-record>serial=${serial}</txt-record>${name:+
    <txt-record>name=${name}</txt-record>}
  </service>
</service-group>
EOF

# Set WiFi AP SSID with the name, else the CPU serial, in NetworkManager connection profiles.
# FlipperOne_6GHz_ leaves 16 of an SSID's 32 bytes: all a serial takes, not all a name or a
# machine-id may, and NetworkManager refuses a longer one.
ssid_suffix=$(printf '%.16s' "${name:-$serial}")
sed -i "s/WIFISSIDSERIAL/${ssid_suffix}/" /etc/NetworkManager/system-connections/wifi-router*.nmconnection 2>/dev/null || true
nmcli connection reload 2>/dev/null || true

systemd-machine-id-setup

# On disk before the marker exists: a reset here leaves committed inodes with no contents, and the
# banner appearing first would mean a hostname, machine-id or avahi service that never landed.
sync

# A Name line for the banner, only for a device that has a name
name_line=${name:+"Name:         $name"}

# The SSH welcome banner, written last on purpose: the unit keys its retry off this file, so it
# must not appear until everything above it is done.
cat <<EOF >/etc/ssh/welcome_banner
=================== Welcome to FlipperOne ===================
Git:          $build_git
Board:        $board${name_line:+
$name_line}
CPU Serial:   $serial
Memory:       $total_mem
Build ID:     $build_id
Profile:      $profile
Default credentials: user / user
=============================================================
EOF

sync
