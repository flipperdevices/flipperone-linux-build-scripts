#!/bin/bash
set -e

# Extract board name from device tree
board=$(cat /sys/firmware/devicetree/base/compatible | tr '\0' '\n' | awk -F, '$2 != "rk3576" { print $2; exit }')

codename=$(. /etc/os-release; echo "${ID}${VERSION_ID}-${BUILD_ID}")
new_hostname="${board:-rk3576}-${codename}"
current_hostname=$(cat /etc/hostname 2>/dev/null ||:)

if [ "${current_hostname}" != "${new_hostname}" ]; then
    echo "${new_hostname}" > /etc/hostname
    hostnamectl set-hostname "${new_hostname}" 2>/dev/null
fi
