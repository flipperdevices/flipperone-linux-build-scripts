#!/usr/bin/env bash
set -euo pipefail

# Print this device's name, e.g. "Jelujelel". Usage: flipper-name.sh [serial]
#
# Derived from the CPU ID in OTP, so it survives reflashing with no factory
# programming step. rockchip-otp is read-only upstream (rk3576_data has .reg_read
# only), so an assigned name would need a U-Boot write path and production tooling.

# Paths, overridable for --self-test fixtures.
override=${FLIPPER_NAME_FILE:-/etc/flipper-name}
denylist=${FLIPPER_DENYLIST_FILE:-/usr/share/flipper/name-denylist}

if [ "${1:-}" = --self-test ]; then
    self=$(realpath "$0")
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    fail=0
    # Ignore whatever this device has installed.
    export FLIPPER_NAME_FILE="$tmp/absent" FLIPPER_DENYLIST_FILE="$tmp/absent"
    check() { # description, expected, actual
        if [ "$2" = "$3" ]; then
            echo "ok   - $1"
        else
            echo "FAIL - $1: expected '$2', got '$3'"
            fail=1
        fi
    }

    a=$("$self" 0123456789abcdef)
    check "deterministic" "$a" "$("$self" 0123456789abcdef)"
    check "differs for another serial" "different" \
        "$([ "$a" != "$("$self" fedcba9876543210)" ] && echo different || echo same)"
    check "CVCVCVCVC, capitalised" "match" \
        "$(echo "$a" | grep -qE '^[BCDFGHJKLMNPRSTVWZ][aeiou][bcdfghjklmnprstvwz][aeiou][bcdfghjklmnprstvwz][aeiou][bcdfghjklmnprstvwz][aeiou][bcdfghjklmnprstvwz]$' && echo match || echo "no match ($a)")"

    # Deny the whole name so the reroll has to move off every letter.
    echo "${a,}" >"$tmp/deny"
    check "rerolls past a denied name" "rerolled" \
        "$([ "$a" != "$(FLIPPER_DENYLIST_FILE=$tmp/deny "$self" 0123456789abcdef)" ] \
            && echo rerolled || echo "stuck on $a")"

    printf 'Tada\n' >"$tmp/override"
    check "override wins" "Tada" "$(FLIPPER_NAME_FILE=$tmp/override "$self" 0123456789abcdef)"

    # Empty override must not produce an empty name.
    : >"$tmp/empty"
    check "empty override falls through" "$a" \
        "$(FLIPPER_NAME_FILE=$tmp/empty "$self" 0123456789abcdef)"

    # A serial with no hex digits must still yield a name rather than crash.
    check "serial with no hex digits still yields a name" "match" \
        "$("$self" zzzz | grep -qE '^[A-Z][a-z]{8}$' && echo match || echo empty)"

    # The name space is only worth quoting if the fold actually reaches it. 500
    # serials against 18^5 * 5^4 expect 0.0001 collisions, so any duplicate here
    # means the hash or gen_name has collapsed into a narrow subspace.
    n=0
    while [ "$n" -lt 500 ]; do
        printf '%016x\n' "$n"
        n=$((n + 1))
    done >"$tmp/serials"
    distinct=$(while read -r s; do "$self" "$s"; done <"$tmp/serials" | sort -u | wc -l)
    check "500 serials give 500 distinct names" "500" "$distinct"

    [ "$fail" -eq 0 ] && echo "all passed"
    exit "$fail"
fi

# /etc/flipper-name overrides the derived name, for a factory-assigned name or a
# user rename.
if [ -s "$override" ]; then
    read -r assigned <"$override" || true
    if [ -n "${assigned:-}" ]; then
        printf '%s\n' "$assigned"
        exit 0
    fi
fi

# Same DT -> OTP -> machine-id chain as set-hostname-and-banner.sh. Callers that
# already have the serial should pass it in.
serial="${1:-}"
if [ -z "$serial" ]; then
    serial=$(tr -d '\0' </sys/firmware/devicetree/base/serial-number 2>/dev/null \
        || rk3576_cpu_serial.sh 2>/dev/null | tail -n1 | awk -F"\t" '{ print $2 }' \
        || cat /etc/machine-id)
fi

# Fold the serial down to 63 bits. It is already a crc32 pair over the OTP CPU ID
# (see rk3576_cpu_serial.sh), so a plain hex fold is enough to spread devices out.
# Not security relevant. The fold has to stay wider than the name space below, or
# some names get more preimages than others and collisions rise above the rate
# quoted there.
hex=${serial//[^0-9a-fA-F]/}
[ -n "$hex" ] || hex=0
h=0
for ((i = 0; i < ${#hex}; i++)); do
    h=$(((h * 31 + 16#${hex:i:1}) & 0x7fffffffffffffff))
done

# Alternating consonant/vowel keeps names pronounceable. CVCVCVCVC over these sets
# is 18^5 * 5^4 = 1,180,980,000 names. That is not collision free. Measured over
# random 64-bit serials, a fleet of 1,000,000 devices contains ~450 that share a
# name with another (~6% above the birthday bound of 423; the fold above is simple
# rather than a strong mixer). The serial stays the identity, the name is only the
# label on it.
cons=(b c d f g h j k l m n p r s t v w z)
vows=(a e i o u)
nc=${#cons[@]}
nv=${#vows[@]}

gen_name() {
    local n=$1 out="" slot
    for slot in c v c v c v c v c; do
        if [ "$slot" = c ]; then
            out+=${cons[n % nc]}
            n=$((n / nc))
        else
            out+=${vows[n % nv]}
            n=$((n / nv))
        fi
    done
    printf '%s' "$out"
}

# Some generated names spell something that must not ship on a device or be
# broadcast as an SSID. Reroll past those.
blocked() {
    local candidate=$1 entry
    [ -f "$denylist" ] || return 1
    while read -r entry; do
        entry=${entry%%#*}
        entry=${entry//[[:space:]]/}
        [ -n "$entry" ] || continue
        [[ $candidate == *"$entry"* ]] && return 0
    done <"$denylist"
    return 1
}

name=$(gen_name "$h")
for _ in {1..16}; do
    blocked "$name" || break
    # Same width as the fold, so a rerolled name is not confined to a subspace.
    # The multiply overflows and wraps, which is what an LCG wants.
    h=$(((h * 6364136223846793005 + 1442695040888963407) & 0x7fffffffffffffff))
    name=$(gen_name "$h")
done

printf '%s\n' "${name^}"
