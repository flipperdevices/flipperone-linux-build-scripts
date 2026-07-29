#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# flipper-bls.sh - shared library for Flipper One BLS boot-entry generation.
#
# SOURCED, never executed. Defines the helpers used by the kernel-install plugin
# (90-loaderentry.install) and the btrfs snapshot tooling (create-profile/rename-profile).
# Functions read globals lazily (at call time), so callers set what they need first.
# The kernel/initrd staging and devicetree(dir) handling are derived from systemd's
# 90-loaderentry.install (LGPL-2.1-or-later).

VENDOR=rockchip
TITLE_MAX="${FLIPPER_TITLE_MAX:-26}"

log() { [ "${KERNEL_INSTALL_VERBOSE:-0}" -gt 0 ] && echo "flipper-bls: $*" >&2; return 0; }
die() { echo "flipper-bls: $*" >&2; exit 1; }
trim() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
# copy a file into the entry dir as root:root 0644
stage_file() { install -m 0644 -o root -g root "$1" "$2" || die "could not copy '$1'"; }

# absolute path under BOOT_ROOT -> path as it must appear inside a BLS entry (relative to the
# boot partition; identical to the absolute path while /boot is on the rootfs). On Flipper One
# BOOT_MNT=/ (/boot is a subvol on the root partition, never a separate boot partition).
boot_rel() { if [ "${BOOT_MNT:-/}" = "/" ]; then printf '%s\n' "$1"; else printf '%s\n' "${1#"${BOOT_MNT}"}"; fi; }

has_config() { [ -f "$KCONFIG" ] && grep -q "^CONFIG_$1=[ym]" "$KCONFIG"; }

# Last rootflags=subvol= value in a cmdline/options string (empty if none).
subvol_of() { printf '%s' "$1" | tr ' ' '\n' | sed -n 's/^rootflags=subvol=//p' | tail -n1; }

# BLS sort-key from os-release (IMAGE_ID, else ID); empty if the root has no os-release.
# $1 = mounted root to describe (default /). Reads the TARGET's os-release and nothing else: under
# -d the running root is a different image entirely, and in a recovery boot its ID is the recovery
# system's, so borrowing it would put the wrong name on the entry rather than no name at all.
os_sort_key() {
    _osr="${1:-}/etc/os-release"
    [ -r "$_osr" ] || { log "no os-release in ${1:-/}, entry gets no sort-key"; return 0; }
    ( . "$_osr"; printf '%s' "${IMAGE_ID:-$ID}" ) || :
}

# Set DTB_DIR + DTB_DIRS (primary dir + modules fallback) for the current $KERNEL_VERSION.
set_dtb_dirs() { DTB_DIR="/usr/lib/linux-image-$KERNEL_VERSION"; DTB_DIRS="$DTB_DIR /usr/lib/modules/$KERNEL_VERSION/dtb"; }

# Kernel entry-token for a root: <NN>-flipperos-<subvol sans @>, carrying the menu band + root id.
# Empty NN -> plain flipperos-<name> (sorts above the numbered bands, like an unmappable root).
make_token() {  # $1 = NN (may be empty)  $2 = subvol
    _n="$(printf '%s' "$2" | tr -d '@')"
    [ -n "$1" ] && printf '%s-flipperos-%s' "$1" "$_n" || printf 'flipperos-%s' "$_n"
}

# Set KERNEL_ENTRY + INITRD_ENTRIES for $KERNEL_VERSION, preferring the profile's own copies in
# /usr/lib/modules/<ver>/ (referenced as /@<subvol>/..., which U-Boot resolves from subvolid 5),
# else the shared /boot copies (BSP/pre-deb-pkg kernels). $1 = subvol; $2 = its mounted root (def /).
resolve_kernel_paths() {
    _rk_root="${2:-/}"; [ "$_rk_root" = / ] && _rk_root=""
    _rk_um="/usr/lib/modules/$KERNEL_VERSION"
    _rk_pfx="$(fdt_prefix "rootflags=subvol=$1")"
    if   [ -f "$_rk_root$_rk_um/vmlinuz" ];        then KERNEL_ENTRY="$_rk_pfx$_rk_um/vmlinuz"
    elif [ -f "/boot/vmlinuz-$KERNEL_VERSION" ];   then KERNEL_ENTRY="$(boot_rel "/boot/vmlinuz-$KERNEL_VERSION")"
    else echo "flipper-bls: no kernel image for $KERNEL_VERSION (looked in $_rk_um and /boot)" >&2; return 1; fi
    if   [ -f "$_rk_root$_rk_um/initrd" ];         then INITRD_ENTRIES="$_rk_pfx$_rk_um/initrd"
    elif [ -f "/boot/initrd.img-$KERNEL_VERSION" ];then INITRD_ENTRIES="$(boot_rel "/boot/initrd.img-$KERNEL_VERSION")"
    else INITRD_ENTRIES=""; fi
}

# KCONFIG for the has_config gates: profile's config first, /boot fallback. $1 = mounted root (def /).
resolve_kconfig() {
    _kc_root="${1:-/}"; [ "$_kc_root" = / ] && _kc_root=""
    if [ -f "$_kc_root/usr/lib/modules/$KERNEL_VERSION/config" ]; then KCONFIG="$_kc_root/usr/lib/modules/$KERNEL_VERSION/config"
    else KCONFIG="/boot/config-$KERNEL_VERSION"; fi
}

# U-Boot reads the btrfs TOP LEVEL (subvolid 5), so in-entry devicetreedir/overlay paths need the
# entry's own root subvol prefixed (/@<subvol>/usr/lib/...), taken from its rootflags=subvol=.
# Set FDT_SUBVOL_PREFIX to override (e.g. "" if the root isn't a subvol).
fdt_prefix() {  # $1 = options string -> "/<rootflags-subvol>" (or $FDT_SUBVOL_PREFIX if set)
    if [ "${FDT_SUBVOL_PREFIX+x}" = x ]; then printf '%s' "$FDT_SUBVOL_PREFIX"; return 0; fi
    _sv=$(subvol_of "$1")
    [ -n "$_sv" ] && printf '/%s' "$_sv"
    return 0
}

# Copies of flipper-btrfs.sh's booted_subvol/booted_fsuuid, kept byte-identical: kernel-install
# sources this file without that one, so it needs its own. Keep the bodies in sync with it.
booted_subvol() {
    _cs=$(findmnt -nro FSROOT / 2>/dev/null | sed 's,^/,,')
    [ -n "$_cs" ] || _cs=$(btrfs subvolume show / 2>/dev/null | sed -n '1{s,^/*,,;s,[[:space:]]*$,,;p}')
    printf '%s' "$_cs"
}

booted_fsuuid() {
    _fu=$(findmnt -nro UUID / 2>/dev/null)
    [ -n "$_fu" ] || _fu=$(btrfs filesystem show / 2>/dev/null | sed -n 's/.*[[:space:]]uuid:[[:space:]]*//p' | head -1)
    printf '%s' "$_fu"
}

# Remove loader entries whose options select SUBVOL and whose version == VERSION. Content-based
# (token/filename-agnostic), so it leaves every other root's entries untouched. Uses $ENTRIES.
remove_entries() {  # $1 = subvol  $2 = version
    [ -n "$1" ] && [ -n "$2" ] || return 0
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        [ "$(awk '$1=="version"{print $2; exit}' "$_c")" = "$2" ] || continue
        _es="$(awk '$1=="options"{for(i=2;i<=NF;i++) if($i ~ /^rootflags=subvol=/) s=$i}
                    END{sub(/^rootflags=subvol=/,"",s); print s}' "$_c")"
        [ "$_es" = "$1" ] && rm -f "$_c" || true
    done
    return 0   # a non-matching last entry must not fail the loop under set -e
}

# Tear down a whole root: remove EVERY entry that selects SUBVOL (all versions) and each one's
# /boot/<token>/ staging tree. The staging dir is derived from the entry's own 'linux' line, so it
# works no matter how the token was computed. For delete-profile/rename-profile (whole-profile ops).
# Uses $ENTRIES. Prints what it removes to stderr.
remove_root_entries() {  # $1 = subvol
    [ -n "$1" ] || return 0
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        _es="$(awk '$1=="options"{for(i=2;i<=NF;i++) if($i ~ /^rootflags=subvol=/) s=$i}
                    END{sub(/^rootflags=subvol=/,"",s); print s}' "$_c")"
        [ "$_es" = "$1" ] || continue
        _lx="$(awk '$1=="linux"{print $2; exit}' "$_c")"
        rm -f "$_c"; echo "removed boot entry $_c" >&2
        case "$_lx" in /boot/*/*/linux)
            _td="${_lx%/*/linux}"; [ "$_td" != /boot ] && rm -rf "$_td" ;;
        esac
    done
    return 0
}

# Base menu slot (900,800,700,... by flipper-profiles position) for the profile $1 belongs to.
# Which profile list to read bands from: the target's own copy when it has one, else the running
# root's. flipper_write_entry can be pointed at a filesystem we did not boot from, whose bands are
# defined by its own list.
target_profiles() {
    if [ -f "${1:-}/etc/kernel/flipper-profiles" ]; then printf '%s' "$1/etc/kernel/flipper-profiles"
    else printf '%s' "${PROFILES:-/etc/kernel/flipper-profiles}"; fi
}

# $1 is a btrfs-PARENT name. It anchors on an ACTUAL profile: the exact name (@Desktop) or its
# golden base / snapshot (@Desktop_stock, @Desktop_<stamp>: profile name followed by '_'). A
# hyphen-suffixed clone (@Desktop-2) must NOT match here, so origin_base_depth can walk THROUGH
# it to count clone depth. Empty if none. Steps of 100 leave room for ~99 variants per band.
profile_base_nn() {
    _want="$1"; _pf="${PROFILES:-/etc/kernel/flipper-profiles}"; [ -f "$_pf" ] || return 0
    _j=0
    while IFS='|' read -r _t _s _e _g _d _l; do
        _t="$(echo "$_t" | tr -d '[:space:]')"; case "$_t" in ''|\#*) continue ;; esac
        _sv="$(subvol_of "$_e" | tr -d '[:space:]')"
        [ -n "$_sv" ] && case "$_want" in "$_sv"|"$_sv"_*) printf '%03d' "$((900 - _j * 100))"; return 0 ;; esac
        _j=$((_j + 1))
    done <"$_pf"
    return 0
}

# Origin-profile base slot AND clone depth for a derived root. Clone/snapshot names are arbitrary
# and can chain (a snapshot of a snapshot), so instead of matching the name we WALK the btrfs
# parent_uuid chain up from the subvol at $1, counting hops, until an ancestor is a listed profile
# or its golden base (profile_base_nn). Prints "BASE DEPTH" (e.g. "900 2" = desktop, grandparent);
# depth is the hop count (1 = direct clone, 2 = clone of a clone, ...). Empty if none maps or no
# btrfs. One `subvolume list` covers the whole fs (ancestors need not be mounted).
origin_base_depth() {  # $1 = mounted path (default /)
    command -v btrfs >/dev/null 2>&1 || return 0
    _mp="${1:-/}"
    _cur="$(btrfs subvolume show "$_mp" 2>/dev/null | sed -n 's/.*[Pp]arent UUID:[[:space:]]*//p' | head -n1)"
    [ -n "$_cur" ] && [ "$_cur" != "-" ] || return 0
    # fs-wide table: one row "uuid parent_uuid name" per subvolume
    _tbl="$(btrfs subvolume list -qu "$_mp" 2>/dev/null | awk '{ u="-"; p="-"; for(i=1;i<NF;i++){ if($i=="uuid")u=$(i+1); else if($i=="parent_uuid")p=$(i+1) } print u, p, $NF }')"
    _seen=" "; _depth=0
    while [ -n "$_cur" ] && [ "$_cur" != "-" ]; do
        case "$_seen" in *" $_cur "*) break ;; esac        # cycle guard
        _seen="$_seen$_cur "
        _row="$(printf '%s\n' "$_tbl" | awk -v u="$_cur" '$1==u{print $2, $3; exit}')"
        [ -n "$_row" ] || break
        _depth=$((_depth + 1))
        _pn="${_row#* }"; _pn="${_pn##*/}"                 # this ancestor's name (basename)
        _bn="$(profile_base_nn "$_pn")"
        [ -n "$_bn" ] && { printf '%s %s' "$_bn" "$_depth"; return 0; }
        _cur="${_row%% *}"                                 # follow parent_uuid to the grandparent
    done
    return 0
}

# Clone menu slot for a derived root: origin base + clone-depth (direct clone -> base+1,
# clone of a clone -> base+2, ...), so clones sit just above the profile (whose factory and
# in-profile-install entries share the base slot). $1 = mounted path; $2 = optional origin hint
# (the name it was restored FROM). Prefers the parent-chain walk (true depth); if that yields
# nothing (e.g. parent_uuid left dangling by a move/receive) it falls back to the hint as a direct
# clone (depth 1 -> base+1). Prints a 3-digit NN, or empty if unresolved.
clone_slot() {  # $1 = mounted path (default /); $2 = origin hint (optional)
    _cs_bd="$(origin_base_depth "${1:-/}")"
    if [ -n "$_cs_bd" ]; then
        printf '%03d' "$(( ${_cs_bd%% *} + ${_cs_bd#* } ))"; return 0
    fi
    if [ -n "${2:-}" ]; then
        _cs_b="$(profile_base_nn "${2##*/}")"
        [ -n "$_cs_b" ] && printf '%03d' "$(( _cs_b + 1 ))"
    fi
    return 0
}

# Menu titles must fit the small screen: cap total at TITLE_MAX by trimming the (long) version
# while keeping the label intact. Label leads, the (possibly trimmed) version follows.
# (Filenames + the 'version' field keep the full version.)
make_title() {
    _suf="$1"
    _avail=$(( TITLE_MAX - ${#_suf} - 1 ))
    if [ "$_avail" -ge 1 ]; then
        printf '%s %s' "$_suf" "$(printf '%s' "$KERNEL_VERSION" | cut -c"1-$_avail")"
    else
        printf '%s' "$_suf" | cut -c"1-$TITLE_MAX"
    fi
}

# write_entry FILE TITLE OPTIONS FDTOVERLAYS
write_entry() {
    _f="$1"; _title="$2"; _opts="$3"; _fdtov="$4"
    # devicetreedir is prefixed with THIS entry's root subvol (U-Boot reads subvolid 5)
    _dtdir=""; [ -n "$DEVICETREEDIR_REL" ] && _dtdir="$(fdt_prefix "$_opts")$DEVICETREEDIR_REL"
    {
        echo "# Boot Loader Specification type#1 entry (Flipper One)"
        echo "title      $_title"
        echo "version    $KERNEL_VERSION"
        [ -n "$MACHINE_ID" ] && [ "$ENTRY_TOKEN" = "$MACHINE_ID" ] && echo "machine-id $MACHINE_ID"
        [ -n "$SORT_KEY" ] && echo "sort-key   $SORT_KEY"
        [ -n "$_opts" ]  && echo "options    $_opts"
        echo "linux      $KERNEL_ENTRY"
        [ -n "$DEVICETREE_ENTRY" ] && echo "devicetree    $DEVICETREE_ENTRY"
        [ -n "$_dtdir" ]           && echo "devicetreedir $_dtdir"
        [ -n "$_fdtov" ]           && echo "devicetree-overlay $_fdtov"
        for _ird in $INITRD_ENTRIES; do echo "initrd     $_ird"; done
    } >"$_f"
    return 0   # don't let a trailing empty conditional's status abort `set -e`
}

# Echo the space-separated paths of the named DT overlays (flat, next to the DTBs).
# Returns non-zero with no output if any one is missing.
overlay_paths() {  # $1 = subvol prefix (e.g. /@Desktop); remaining args = overlay names
    _pfx="$1"; shift
    _paths=""
    for _n in "$@"; do
        [ -f "$OVERLAY_DIR/$_n.dtbo" ] || return 1   # check the real on-disk path
        _paths="$_paths${_paths:+ }$_pfx$OVERLAY_DIR/$_n.dtbo"
    done
    printf '%s' "$_paths"
}

# Set BASE_OPTS from CONF_ROOT/cmdline (root=UUID + policy) + this kernel's console layout.
# FIQ kernel -> console=ttyFIQ0 ; mainline -> console=ttyS0 + ttyS4 + fbcon=map:1.
compute_base_opts() {
    if [ -f "$CONF_ROOT/cmdline" ]; then
        BASE_OPTS="$(grep -Gv '^\s*#' "$CONF_ROOT/cmdline" | tr -s '[:space:]' ' ')"
    elif [ -f /usr/lib/kernel/cmdline ]; then
        BASE_OPTS="$(grep -Gv '^\s*#' /usr/lib/kernel/cmdline | tr -s '[:space:]' ' ')"
    else
        BASE_OPTS=""
    fi
    BASE_OPTS="$(trim "$BASE_OPTS")"
    # rewrite the shipped cmdline's build-time root=UUID to the fs we install onto, so a _stock
    # received onto a device with a different btrfs UUID still boots.
    # the filesystem the entry will boot from, which under -d is not the one we are running
    _fsuuid="${TARGET_FSUUID:-$(booted_fsuuid)}"
    [ -n "$_fsuuid" ] && BASE_OPTS="$(printf '%s' " $BASE_OPTS " | sed "s/ root=UUID=[^ ]*/ root=UUID=$_fsuuid/")"
    BASE_OPTS="$(trim "$BASE_OPTS")"
    # Pin systemd.machine_id= only when entries are named after the machine-id (no-op otherwise).
    if [ -n "$MACHINE_ID" ] && [ "$ENTRY_TOKEN" = "$MACHINE_ID" ] && ! echo "$BASE_OPTS" | grep -q "systemd.machine_id="; then
        BASE_OPTS="$BASE_OPTS systemd.machine_id=$MACHINE_ID"
    fi
    if has_config FIQ_DEBUGGER_CONSOLE; then
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyS0,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") console=ttyFIQ0,1500000n8"
    else
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyS0,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") console=ttyS0,1500000n8"
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyS4,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") console=ttyS4,1500000n8"
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyFIQ0,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") fbcon=map:1"
    fi
}

# Set DEVICETREEDIR_REL + OVERLAY_DIR for $KERNEL_VERSION (needs DTB_DIR/DTB_DIRS set). Opt-in via a
# /etc/kernel/devicetreedir boolean, only when no single 'devicetree' is configured. Always the
# kernel's own installed DTB dir (first existing of DTB_DIRS), never inspected or borrowed; if it
# ships none, no devicetreedir is written and U-Boot falls back to its control FDT.
discover_devicetreedir() {
    DEVICETREEDIR_SRC=""; DEVICETREEDIR_REL=""
    if [ -z "${DEVICETREE:-}" ] && [ -f "$CONF_ROOT/devicetreedir" ]; then
        _v=""; read -r _v <"$CONF_ROOT/devicetreedir" || :
        case "$_v" in
            1|[Yy]|[Yy][Ee][Ss]|[Tt]|[Tt][Rr][Uu][Ee]|[Oo][Nn])
                for p in $DTB_DIRS; do
                    [ -d "$p" ] && { DEVICETREEDIR_SRC="$p"; break; }
                done
                if [ -n "$DEVICETREEDIR_SRC" ]; then
                    DEVICETREEDIR_REL="$(boot_rel "$DEVICETREEDIR_SRC")"   # /usr/lib/...; prefixed per entry
                else
                    log "$KERNEL_VERSION ships no DTB dir; omitting devicetreedir (U-Boot control FDT)"
                fi
                ;;
        esac
    fi
    # DT overlays sit flat next to the .dtb files (upstream layout), in the same vendor dir.
    OVERLAY_DIR="${DEVICETREEDIR_SRC:-$DTB_DIR}/$VENDOR"
}

# emit_entry SUF EXTRA GATE DTBOS -> write one BLS entry for the current $ENTRY_TOKEN.
# The filename is $ENTRY_TOKEN-$KERNEL_VERSION.conf. The token is <NN>-flipperos-<subvol>, so it
# LEADS with the 3-digit menu band and U-Boot's bls (filename sort, descending) orders entries by
# band then version. EXTRA carries this entry's rootflags=subvol=; BASE_OPTS has none, so there is
# exactly one per entry. Honours gate (skip if a CONFIG_ symbol is missing) + overlays.
emit_entry() {
    _suf="$1"; _extra="$2"; _gate="$3"; _dtbos="$4"

    # gate may list several config symbols; all must be present in this kernel.
    for _g in $_gate; do
        has_config "$_g" || { log "skip $ENTRY_TOKEN (CONFIG_$_g not set for $KERNEL_VERSION)"; return 0; }
    done

    _opts="$BASE_OPTS"
    [ -n "$_extra" ] && _opts="$_opts $_extra"
    _fn="$ENTRIES/$ENTRY_TOKEN-$KERNEL_VERSION.conf"

    if [ -z "$_dtbos" ]; then
        write_entry "$_fn" "$(make_title "$_suf")" "$_opts" ""
        return 0
    fi

    # A leading '!' on the overlay list = required (skip the entry if the overlays are
    # absent); otherwise optional (the entry is still written, sans overlay).
    _required=0
    case "$_dtbos" in '!'*) _required=1; _dtbos="$(trim "${_dtbos#\!}")" ;; esac

    _paths="$(overlay_paths "$(fdt_prefix "$_opts")" $_dtbos)" || _paths=""
    if [ -z "$_paths" ] && [ "$_required" = 1 ]; then
        log "skip $ENTRY_TOKEN (overlays not found for $KERNEL_VERSION)"
        return 0
    fi
    write_entry "$_fn" "$(make_title "$_suf")" "$_opts" "$_paths"
}

# flipper_write_entry <subvol> <mounted-path> [<origin-hint>]: write a BLS entry for an EXISTING
# writable top-level subvol (a restored snapshot/clone). Token = <NN>-flipperos-<name>, NN from
# clone_slot (origin base + depth; the origin hint is the dangling-parent fallback). Points the
# entry at the root's OWN kernel+initrd in /usr/lib/modules/<ver>/ (resolve_kernel_paths), so no
# /boot staging. Sourced by create-profile / rename-profile. Returns non-zero on a recoverable problem.
flipper_write_entry() {
    _name="$1"; _snap="$2"; _origin="${3:-}"
    { [ -n "$_name" ] && [ -d "$_snap" ]; } || { echo "flipper-bls: usage: flipper_write_entry <name> <mounted-path>" >&2; return 1; }
    ENTRIES="${ENTRIES:-/boot/loader/entries}"
    # The base cmdline (root=UUID and policy) belongs to the root being written, not to whatever
    # is running. kernel-install still wins when it sets its own conf root. Without this, an entry
    # written from a recovery boot came out with no root= at all, and so could not boot.
    if [ -n "${KERNEL_INSTALL_CONF_ROOT:-}" ]; then CONF_ROOT="$KERNEL_INSTALL_CONF_ROOT"
    elif [ -f "$_snap/etc/kernel/cmdline" ]; then CONF_ROOT="$_snap/etc/kernel"
    else CONF_ROOT=/etc/kernel; fi
    MACHINE_ID=""; DEVICETREE=""; DEVICETREE_ENTRY=""
    # version from the target's OWN tree, so modules + dtbs are self-consistent
    KERNEL_VERSION="$(ls -1d "$_snap"/usr/lib/linux-image-* 2>/dev/null | sed 's,.*/linux-image-,,' | sort -V | tail -n1)"
    [ -n "$KERNEL_VERSION" ] || { echo "flipper-bls: no /usr/lib/linux-image-* inside $_name" >&2; return 1; }
    resolve_kconfig "$_snap"
    set_dtb_dirs
    SORT_KEY="$(os_sort_key "$_snap")"
    # The band comes from the profile list, which lives INSIDE a profile, not in the /etc of
    # whatever is running. Under -d the running root may have no list at all (recovery), and an
    # empty band silently drops the sort prefix from the entry filename.
    PROFILES="${PROFILES:-$(target_profiles "$_snap")}"
    ENTRY_TOKEN="$(make_token "$(clone_slot "$_snap" "$_origin")" "$_name")"
    mkdir -p "$ENTRIES" || { echo "flipper-bls: cannot create $ENTRIES" >&2; return 1; }
    compute_base_opts
    resolve_kernel_paths "$_name" "$_snap" || return 1
    # devicetreedir is the target root's OWN kernel dir (KERNEL_VERSION came from it, so it exists).
    DEVICETREEDIR_REL="/usr/lib/linux-image-$KERNEL_VERSION"
    OVERLAY_DIR="$DTB_DIR/$VENDOR"
    # pin the root's own entry-token so a later runtime apt install in it lands in the same band
    mkdir -p "$_snap/etc/kernel" && printf '%s\n' "$ENTRY_TOKEN" > "$_snap/etc/kernel/entry-token"
    # Remove any existing entry for this root+version first. The entry filename holds a sort
    # number tied to the profile's btrfs snapshot depth, which changes when a profile is
    # re-created; a new entry would then get a different filename instead of overwriting the
    # old one, leaving a duplicate. Deleting first refreshes it in place.
    remove_entries "$_name" "$KERNEL_VERSION"
    emit_entry "$(printf '%s' "$_name" | tr -d '@')" "rootflags=subvol=$_name" "" ""
    echo "flipper-bls: wrote entry for $_name (kernel $KERNEL_VERSION, token $ENTRY_TOKEN)"
}
