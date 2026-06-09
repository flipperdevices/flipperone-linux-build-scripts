#!/usr/bin/env bash
set -euo pipefail

nvmem="/sys/bus/nvmem/devices/rockchip-otp0/nvmem"
cpuid_offset=$((0x0a))
cpuid_length=$((0x10))  # 16 bytes

# U-Boot-compatible crc32_no_comp:
# - reflected CRC-32 (poly 0xEDB88320)
# - no initial/final one's complement
crc32_no_comp() {
    local crc=$1
    shift
    local b i
    for b in "$@"; do
        crc=$(( (crc ^ b) & 0xffffffff ))
        for ((i = 0; i < 8; i++)); do
            if (( crc & 1 )); then
                crc=$(( (crc >> 1) ^ 0xEDB88320 ))
            else
                crc=$(( crc >> 1 ))
            fi
            crc=$(( crc & 0xffffffff ))
        done
    done
    printf "%u\n" "$crc"
}

# Read cpuid_length bytes from OTP at cpuid_offset
mapfile -t cpuid_hex < <(
    dd if="$nvmem" bs=1 skip="$cpuid_offset" count="$cpuid_length" status=none |
    od -An -tx1 -v |
    tr -s '[:space:]' '\n' |
    sed '/^$/d'
)

if (( ${#cpuid_hex[@]} != cpuid_length )); then
    echo "Failed to read ${cpuid_length} bytes from $nvmem" >&2
    exit 1
fi

# Build cpuid string and split bytes into low/high per rockchip_cpuid_set()
cpuid_str=""
low=()
high=()
for ((i = 0; i < cpuid_length; i++)); do
    byte_hex="${cpuid_hex[i],,}"
    cpuid_str+="$byte_hex"
    byte_val=$((16#$byte_hex))

    if (( i % 2 == 0 )); then
        high+=("$byte_val")   # cpuid[0], cpuid[2], ...
    else
        low+=("$byte_val")    # cpuid[1], cpuid[3], ...
    fi
done

serial_lo=$(crc32_no_comp 0 "${low[@]}")
serial_hi=$(crc32_no_comp "$serial_lo" "${high[@]}")

# C code does: serial = lo | (hi << 32), then "%016llx"
serialno_str=$(printf "%08x%08x" $((serial_hi & 0xffffffff)) $((serial_lo & 0xffffffff)))

echo "cpuid:	$cpuid_str"
echo "serial:	$serialno_str"
