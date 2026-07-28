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
# Guard for the -d/--device value: fail (with the tool's usage) if the flag was the last token.
# Call with the arg count remaining AFTER shifting the flag off:
#   -d|--device) shift; need_device_arg "$#"; ROOTDEV=$1 ;;
need_device_arg() { [ "$1" -ge 1 ] || { echo "Error: --device needs an argument" >&2; usage >&2; exit 1; }; }

# True if / is a btrfs mount (a normally booted system, not a RAM recovery root).
root_is_btrfs() { [ "$(findmnt -no FSTYPE / 2>/dev/null)" = btrfs ]; }

# The subvolume mounted at / (e.g. @Desktop), empty if there is none. findmnt cannot answer inside a
# chroot, so fall back to asking btrfs. flipper-bls.sh keeps its own copy: kernel-install hooks
# source that file without this one.
current_subvol() {
    _cs=$(findmnt -nro FSROOT / 2>/dev/null | sed 's,^/,,')
    [ -n "$_cs" ] || _cs=$(btrfs subvolume show / 2>/dev/null | sed -n '1{s,^/*,,;s,[[:space:]]*$,,;p}')
    printf '%s' "$_cs"
}

# btrfs FS UUID of the mounted root, empty if unknown. Same reasoning as current_subvol.
current_fsuuid() {
    _fu=$(findmnt -nro UUID / 2>/dev/null)
    [ -n "$_fu" ] || _fu=$(btrfs filesystem show / 2>/dev/null | sed -n 's/.*[[:space:]]uuid:[[:space:]]*//p' | head -1)
    printf '%s' "$_fu"
}

# The two option help lines nearly every tool repeats verbatim in its usage(). Kept here so the
# wording cannot drift between tools; interpolated inside their heredocs. migrate-profile spells
# its own out, its -y means something more specific and its help column is wider.
HELP_YES="  -y,--yes    assume yes to prompts (non-interactive)"
HELP_DEVICE="  -d,--device operate on btrfs filesystem DEV instead of the booted root (e.g. recovery)"

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
    # Arm cleanup FIRST: callers set TOP_TMPFILES before calling us, so a die on the checks below
    # (a bad -d argument, no btrfs root) must still take their temp files with it.
    trap 'top_cleanup' EXIT
    # dash runs the EXIT trap on exit, not on a signal, so a plain kill would leave $TOP mounted;
    # route the usual signals through exit so the cleanup happens once, in one place
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    [ -n "${ROOTDEV:-}" ] || ROOTDEV=$(findmnt -no SOURCE / | sed 's/\[.*//')
    [ -n "$ROOTDEV" ] || die "Cannot determine root device (use -d/--device)"
    [ -b "$ROOTDEV" ] || die "Not a block device: $ROOTDEV"
    TOP=$(mktemp -d)
    _err=$(mount -o subvolid=5 "$ROOTDEV" "$TOP" 2>&1) || die "Mount failed: $_err"
}
top_cleanup() {
    if [ -n "${TOP:-}" ]; then
        for _i in 1 2 3 4 5; do
            umount "$TOP" 2>/dev/null && break
            # the callers run under set -e, where a failing detach would abort the trap and
            # abandon the mount
            [ "$_i" = 5 ] && umount -l "$TOP" 2>/dev/null || true
            sleep 1
        done
        rmdir "$TOP" 2>/dev/null || true
    fi
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

# The timestamp every generated name uses (snapshots, aside copies, ro sends). One helper so
# the names stay mutually parseable: list-profiles keys KIND=old off this exact shape.
stamp() { date +%Y-%m-%d_%H-%M-%S; }

# Top-relative path of the subvolume with this uuid, empty if none. $1 = top mount, $2 = uuid.
path_of_uuid() {
    case "$2" in ''|'-') return ;; esac
    btrfs subvolume list -u "$1" 2>/dev/null | awk -v u="$2" '
        { p=""; uu=""
          for (i=1;i<=NF;i++) { if($i=="uuid")uu=$(i+1); else if($i=="path"){p=$(i+1);for(j=i+2;j<=NF;j++)p=p" "$j} }
          if (uu==u){print p; exit} }'
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
# profile's base after the btrfs parent chain is broken by deletions. Records the stock's own
# name and its build id (BUILD_GIT from os-release). Profiles snapshotted from the stock inherit
# the file; matching later is by name + BUILD_GIT, not by uuid (uuid is cleared by snapshots).
# $1 = the stock's mounted dir, $2 = the stock's name (e.g. @Desktop_stock).
stamp_stock_origin() {
    _bg=$( . "$1/etc/os-release" >/dev/null 2>&1; printf '%s' "${BUILD_GIT:-}" ) || _bg=
    [ -n "$_bg" ] || _bg=-
    printf 'origin_stock_name=%s\norigin_base_build=%s\n' "$2" "$_bg" > "$1/etc/profile_origin"
}
