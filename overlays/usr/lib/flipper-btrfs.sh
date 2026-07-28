#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# flipper-btrfs.sh - shared helpers for the Flipper One btrfs profile/snapshot tooling.
#
# SOURCED, never executed. Defines the preamble (root/btrfs checks), the top-level
# (subvolid=5) mount, and the small helpers duplicated across create-profile,
# create-snapshot, delete-profile, delete-snapshot, list-profiles, list-snapshots,
# btrfs-maintenance, receive-snapshot, rename-profile, send-snapshot, migrate-profile and btrfs-show-space.
# Functions read globals lazily, so callers set what they need first.

die() { echo "Error: $*" >&2; exit 1; }

need_root()  { [ "$(id -u)" -eq 0 ] || die "Must run as root (use sudo)"; }
need_btrfs() { command -v btrfs >/dev/null 2>&1 || die "Btrfs-progs not installed"; }
need_cmd()   { command -v "$1" >/dev/null 2>&1 || die "Command not installed: $1${2:+ ($2)}"; }

# True if / is a btrfs mount (a normally booted system, not a RAM recovery root).
root_is_btrfs() { [ "$(findmnt -no FSTYPE / 2>/dev/null)" = btrfs ]; }

# Non-interactive switch for confirm(): set to 1 by -y/--yes, or via the environment
# (ASSUME_YES=1 <tool> ...) so the tools can run unattended from scripts.
ASSUME_YES=${ASSUME_YES:-0}

# Ask on stderr, read stdin; abort unless yes. $1 may span lines. -y/--yes auto-confirms.
confirm() {
    if [ "$ASSUME_YES" = 1 ]; then printf '%s [auto-yes]\n' "$1" >&2; return 0; fi
    printf '%s [y/N] ' "$1" >&2
    read -r _a || die "Aborted"
    case "$_a" in y|Y|yes|YES) return 0 ;; *) die "Aborted" ;; esac
}

# Reserved subvolumes the tools must never write/delete/rename.
is_reserved_subvol() {
    case "$1" in
        @|@home|@root|@snapshots|@stock-snapshots|@var-log|@var-cache|boot) return 0 ;;
        *) return 1 ;;
    esac
}

# Reject a profile (top-level subvol) name that would break rootflags=subvol= on the kernel
# cmdline and leave the profile unbootable. Requires a leading '@' and only [A-Za-z0-9_-].
validate_profile_name() {
    case "$1" in
        *..*|/*|*/*) die "Invalid profile name: $1 (top-level name only, e.g. @Desktop-2)" ;;
    esac
    case "$1" in
        @?*) ;;
        *) die "Profile name must start with '@' (e.g. @Desktop-2): $1" ;;
    esac
    case "$1" in
        *[!@A-Za-z0-9_-]*) die "Profile name has symbols that are not allowed: $1 (use only letters, digits, '-', '_')" ;;
    esac
}

# Serialize our writers: an exclusive advisory lock (flock) held on FD 9 for the script's
# lifetime, released on any exit (including crash/kill). The holder records "PID (tool)" in the
# file so a blocked waiter can say who it is waiting on. Read-only tools do not take it, and it
# does NOT guard against concurrent native `btrfs` commands, which honor no lock.
LOCK_FILE=/run/flipper-btrfs.lock
set_lock() {
    exec 9<>"$LOCK_FILE" || die "Cannot open lock $LOCK_FILE"   # <> = don't truncate the holder line
    if ! flock -w 0 9 2>/dev/null; then
        _h=$(cat "$LOCK_FILE" 2>/dev/null); [ -n "$_h" ] || _h="PID unknown"
        echo "Another flipper-btrfs operation is in progress ($_h); waiting for it to finish..." >&2
        flock 9 || die "Cannot acquire lock $LOCK_FILE"
    fi
    printf 'PID %s (%s)\n' "$$" "${0##*/}" >"$LOCK_FILE" || true
}

# Mount the btrfs top level (subvolid=5) at a temp dir and arrange teardown on EXIT.
# Sets ROOTDEV and TOP. Extra temp files to remove: assign them to TOP_TMPFILES first.
# ROOTDEV may be preset (by -d/--device) to run against a filesystem that is not the
# booted root, e.g. from a RAM recovery boot where / is not the btrfs filesystem.
mount_top() {
    [ -n "${ROOTDEV:-}" ] || ROOTDEV=$(findmnt -no SOURCE / | sed 's/\[.*//')
    [ -n "$ROOTDEV" ] || die "Cannot determine root device (use -d/--device)"
    [ -b "$ROOTDEV" ] || die "Not a block device: $ROOTDEV"
    TOP=$(mktemp -d)
    trap 'top_cleanup' EXIT
    _err=$(mount -o subvolid=5 "$ROOTDEV" "$TOP" 2>&1) || die "Mount failed: $_err"
}
top_cleanup() {
    [ -n "${TOP:-}" ] && { umount "$TOP" 2>/dev/null || true; rmdir "$TOP" 2>/dev/null || true; }
    [ -n "${TOP_TMPFILES:-}" ] && rm -f $TOP_TMPFILES
    return 0
}

# Resolve a subvol NAME to its top-relative path: as given ($TOP/<name>, e.g. a full
# @snapshots/<name> or @stock-snapshots/@X_stock path), else a bare name found under @snapshots
# (restore points) or @stock-snapshots (golden bases). Prints the path relative to $TOP; empty if
# none exists. Needs $TOP.
resolve_rel() {
    if   [ -e "$TOP/$1" ];                  then printf '%s' "$1"
    elif [ -e "$TOP/@snapshots/$1" ];       then printf '%s' "@snapshots/$1"
    elif [ -e "$TOP/@stock-snapshots/$1" ]; then printf '%s' "@stock-snapshots/$1"
    fi
}

# One field from `btrfs subvolume show` output. $1 = output text, $2 = key label.
get() { printf '%s\n' "$1" | awk -v k="$2" -F':[[:space:]]+' 'index($0,k){print $2; exit}'; }

subvol_id() { get "$(btrfs subvolume show "$1" 2>/dev/null)" "Subvolume ID"; }
booted_id() { subvol_id /; }

# True if the subvolume at $1 is read-only.
is_ro() {
    case "$(btrfs subvolume show "$1" 2>/dev/null | awk -F':[[:space:]]+' '/Flags/{print $2}')" in
        *readonly*) return 0 ;; *) return 1 ;;
    esac
}

human() { numfmt --to=iec-i --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || printf '%s' "${1:-0}"; }

# uuid -> "id <tab> path" for every subvolume, so parents resolve by UUID. $1 = top, $2 = out file.
build_uuid_map() {
    btrfs subvolume list -qu "$1" 2>/dev/null | awk '
    {
        id=""; u=""; p=""
        for (i = 1; i <= NF; i++) {
            if      ($i == "ID")   id = $(i+1)
            else if ($i == "uuid") u  = $(i+1)
            else if ($i == "path") { p = $(i+1); for (j = i+2; j <= NF; j++) p = p" "$j; break }
        }
        if (u != "" && u != "-") print u"\t"id"\t"p
    }' > "$2"
}

# Resolve a parent UUID to "name (id)" via a map from build_uuid_map. $1 = map file, $2 = uuid.
parent_of() {
    case "$2" in ''|'-') printf '%s' "-"; return ;; esac
    awk -F'\t' -v u="$2" '
        $1==u { n=$3; sub(/.*\//,"",n); printf "%s (%s)", n, $2; f=1 }
        END   { if (!f) printf "-" }' "$1"
}

# Print a TSV file with every column padded to its max width; last field left unpadded.
align_table() {
    awk -F'\t' '
    { line[NR]=$0; nf=split($0,a,"\t"); for (i=1;i<=nf;i++) if (length(a[i])>w[i]) w[i]=length(a[i]) }
    END {
        for (r=1; r<=NR; r++) {
            n=split(line[r], a, "\t"); out=""
            for (i=1; i<=n; i++) out = (i<n) ? out sprintf("%-*s  ", w[i], a[i]) : out a[i]
            print out
        }
    }' "$1"
}

# Stamp a _stock's factory-origin marker (/etc/profile_origin) so migrate-profile can find a
# profile's base after the btrfs parent chain is broken by deletions. Profiles snapshotted from
# the stock inherit the file; matching later is by name, not by uuid (a snapshot clears that).
# The name carries the build id (@Desktop_744_stock), so it identifies the exact base on its own.
# $1 = the stock's mounted dir, $2 = the stock's name (e.g. @Desktop_744_stock).
stamp_stock_origin() {
    printf 'origin_stock_name=%s\n' "$2" > "$1/etc/profile_origin"
}
