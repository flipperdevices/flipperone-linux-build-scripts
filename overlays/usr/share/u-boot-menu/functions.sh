#!/bin/sh

# Sanitize board name for use as shell variable suffix
sanitize_board_name() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g'
}

# Escape value for use in eval
escape_for_eval() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

# Get list of discovered boards (space-separated sanitized names)
get_discovered_boards() {
    echo "${_discovered_boards}"
}

# Get original board name from sanitized name
get_original_board_name() {
    local sanitized="$1"
    eval "echo \"\${_board_original_${sanitized}}\""
}

# Register a board (stores both sanitized and original names)
# New boards inherit current state from default entry
register_board() {
    local board="$1"
    local sanitized
    local escaped
    local current_bootargs
    local current_name

    if [ -z "$board" ]; then
        sanitized=""
    else
        sanitized=$(sanitize_board_name "$board")
        eval "_board_original_${sanitized}=\"${board}\""
    fi

    # Check if already registered
    case " ${_discovered_boards} " in
        *" ${sanitized} "*) return 0 ;;
    esac

    _discovered_boards="${_discovered_boards:+${_discovered_boards} }${sanitized}"

    # Get current state from default entry (which may have been modified by features)
    eval "current_name=\"\${profile_name_}\""
    eval "current_bootargs=\"\${profile_bootargs_}\""

    # Initialize per-board variables from current default state
    escaped=$(escape_for_eval "${current_name:-${base_profile_name}}")
    eval "profile_name_${sanitized}='${escaped}'"
    eval "profile_kernel_image_${sanitized}=\"\${base_kernel}\""
    eval "profile_ramdisk_image_${sanitized}=\"\${base_initrd}\""
    eval "profile_fdtdir_${sanitized}=\"\${base_fdtdir}\""
    eval "profile_fdtoverlays_${sanitized}=\"\""
    escaped=$(escape_for_eval "${current_bootargs:-${DEFAULT_BOOTARGS}}")
    eval "profile_bootargs_${sanitized}='${escaped}'"
    eval "skip_entry_${sanitized}=\"\""
}

# Clear all per-board variables and board list
cleanup_boards() {
    local sanitized
    for sanitized in ${_discovered_boards}; do
        eval "unset profile_name_${sanitized}"
        eval "unset profile_kernel_image_${sanitized}"
        eval "unset profile_ramdisk_image_${sanitized}"
        eval "unset profile_fdtdir_${sanitized}"
        eval "unset profile_fdtoverlays_${sanitized}"
        eval "unset profile_bootargs_${sanitized}"
        eval "unset skip_entry_${sanitized}"
        eval "unset _board_original_${sanitized}"
    done
    _discovered_boards=""

    # Also cleanup default (empty) board
    unset profile_name_
    unset profile_kernel_image_
    unset profile_ramdisk_image_
    unset profile_fdtdir_
    unset profile_fdtoverlays_
    unset profile_bootargs_
    unset skip_entry_
}

# Initialize default (non-board-specific) entry
init_default_entry() {
    local escaped
    escaped=$(escape_for_eval "${base_profile_name}")
    eval "profile_name_='${escaped}'"
    profile_kernel_image_="${base_kernel}"
    profile_ramdisk_image_="${base_initrd}"
    profile_fdtdir_="${base_fdtdir}"
    profile_fdtoverlays_=""
    escaped=$(escape_for_eval "${DEFAULT_BOOTARGS}")
    eval "profile_bootargs_='${escaped}'"
    skip_entry_=""
}

# Set base profile name for default and all registered boards
# Usage: set_base_profile_name "name"
set_base_profile_name() {
    local name="$1"
    local sanitized
    local escaped

    # Update the base for future boards
    base_profile_name="$name"

    # Update default entry
    escaped=$(escape_for_eval "$name")
    eval "profile_name_='${escaped}'"

    # Update all already registered boards
    for sanitized in ${_discovered_boards}; do
        eval "profile_name_${sanitized}='${escaped}'"
    done
}

# Add bootargs to all registered boards (not default)
# Usage: add_bootargs_to_boards args...
add_bootargs_to_boards() {
    local args="$*"
    local sanitized

    for sanitized in ${_discovered_boards}; do
        local current=""
        local escaped=""
        eval "current=\"\${profile_bootargs_${sanitized}}\""
        escaped=$(escape_for_eval "${current:+${current} }${args}")
        eval "profile_bootargs_${sanitized}='${escaped}'"
    done
}

# Add bootargs to specific board(s) or default
# Usage: add_bootargs [-b board] [-a] args...
#   -a: add to all registered boards instead of default
add_bootargs() {
    local board=""
    local all_boards=""
    local sanitized=""
    local args=""
    local current=""
    local escaped=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -b) board="$2"; shift 2 ;;
            -a) all_boards=1; shift ;;
            *) break ;;
        esac
    done
    args="$*"

    if [ -n "$all_boards" ]; then
        add_bootargs_to_boards "$args"
        return
    fi

    if [ -n "$board" ]; then
        sanitized=$(sanitize_board_name "$board")
    fi

    eval "current=\"\${profile_bootargs_${sanitized}}\""
    escaped=$(escape_for_eval "${current:+${current} }${args}")
    eval "profile_bootargs_${sanitized}='${escaped}'"
}

# Remove bootargs from specific board(s) or default
# Usage: remove_bootargs [-b board] args...
remove_bootargs() {
    local board=""
    local sanitized=""
    local args=""
    local current=""
    local escaped=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -b) board="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    args="$*"

    if [ -n "$board" ]; then
        sanitized=$(sanitize_board_name "$board")
    fi

    eval "current=\"\${profile_bootargs_${sanitized}}\""
    for arg in $args; do
        current="$(echo "${current}" | sed -E "s/(^| )${arg}( |$)/ /g" | xargs)"
    done
    escaped=$(escape_for_eval "${current}")
    eval "profile_bootargs_${sanitized}='${escaped}'"
}

# Append to profile name for specific board or default
# Usage: append_name [-b board] suffix
append_name() {
    local board=""
    local sanitized=""
    local suffix=""
    local current=""
    local escaped=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -b) board="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    suffix="$*"

    if [ -n "$board" ]; then
        sanitized=$(sanitize_board_name "$board")
    fi

    eval "current=\"\${profile_name_${sanitized}}\""
    escaped=$(escape_for_eval "${current} ${suffix}")
    eval "profile_name_${sanitized}='${escaped}'"
}

# Finalize board names by appending board identifier at the end
# Call this before inject_all_entries
finalize_board_names() {
    local sanitized
    local current
    local escaped
    local original_board

    for sanitized in ${_discovered_boards}; do
        original_board=$(get_original_board_name "$sanitized")
        eval "current=\"\${profile_name_${sanitized}}\""
        escaped=$(escape_for_eval "${current} (${original_board})")
        eval "profile_name_${sanitized}='${escaped}'"
    done
}

# Set skip_entry for a specific board or default
# Usage: set_skip_entry [-b board]
set_skip_entry() {
    local board=""
    local sanitized=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -b) board="$2"; shift 2 ;;
            *) break ;;
        esac
    done

    if [ -n "$board" ]; then
        sanitized=$(sanitize_board_name "$board")
    fi

    eval "skip_entry_${sanitized}=1"
}

add_legend() {
    local legend="$1"
    local description="$2"
    local no_legend="${processed_legend##*\[$legend\]*}"

    [ -z "${processed_legend}" -o -n "${no_legend}" ] || return 0

    [ "${uboot_menu_title}" != "${U_BOOT_MENU_TITLE}" ] ||
        uboot_menu_title="${uboot_menu_title}\e[0m\/==================\eE"

    uboot_menu_title="${uboot_menu_title}\e[0;38;5;208m - ${legend}\e[0m\e[20G${description}\eE"
    processed_legend="${processed_legend}[${legend}]"
}

set_profile_var() {
    local key="$1"; shift
    local board=""
    local sanitized=""
    local value=""
    local escaped=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -b) board="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    value="$*"

    if [ -n "$board" ]; then
        sanitized=$(sanitize_board_name "$board")
    fi

    escaped=$(escape_for_eval "${value}")
    eval "profile_${key}_${sanitized}='${escaped}'"
}

has_config() {
    local config_key="$1"
    local config_file="${BOOT_DIR}/config-${_KERNEL_VERSION}"

    if [ -f "$config_file" ]; then
        egrep -q "^CONFIG_${config_key}=[ym]" "$config_file"
        return $?
    fi
    return 1
}

# Add DTBO to a specific board or default
# Usage: add_dtbo [-b board] dtbo_name
add_dtbo() {
    local board=""
    local sanitized=""
    local dtbo_name=""
    local dtbo_file=""
    local path=""
    local fdtdir=""
    local current=""
    local escaped=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -b) board="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    dtbo_name="$1"
    dtbo_file="${dtbo_name}.dtbo"

    if [ -n "$board" ]; then
        sanitized=$(sanitize_board_name "$board")
    fi

    eval "fdtdir=\"\${profile_fdtdir_${sanitized}}\""
    [ -n "${fdtdir}" ] || return 1

    path="${fdtdir}${U_BOOT_FDT_VENDOR}/overlay/${dtbo_file}"
    [ -f "${path}" ] || return 1

    eval "current=\"\${profile_fdtoverlays_${sanitized}}\""
    escaped=$(escape_for_eval "${current:+${current} }${path}")
    eval "profile_fdtoverlays_${sanitized}='${escaped}'"
}

get_board_name() {
    cat /sys/firmware/devicetree/base/compatible 2>/dev/null | tr '\0' '\n' | awk -F, -vskip_board="${U_BOOT_DT_DETECT_SKIP_BOARD}" '$2 != skip_board { print $2; exit }'
}

# Inject a single record for a board
# Usage: inject_board_record board_sanitized
inject_board_record() {
    local sanitized="$1"
    local profile_id="l${_NUMBER}"
    local name="" kernel="" initrd="" fdtdir="" fdtoverlays="" bootargs=""

    eval "name=\"\${profile_name_${sanitized}}\""
    eval "kernel=\"\${profile_kernel_image_${sanitized}}\""
    eval "initrd=\"\${profile_ramdisk_image_${sanitized}}\""
    eval "fdtdir=\"\${profile_fdtdir_${sanitized}}\""
    eval "fdtoverlays=\"\${profile_fdtoverlays_${sanitized}}\""
    eval "bootargs=\"\${profile_bootargs_${sanitized}}\""

    # Normalize name (trim whitespace)
    name=$(echo "$name" | xargs)

    cat >> "${_EXTLINUX_CONF_TEMP}" <<EOF
label ${profile_id}
    menu label ${name}
    linux ${kernel}
EOF

    if [ -n "${initrd}" ]; then
        echo "    initrd ${initrd}" >> "${_EXTLINUX_CONF_TEMP}"
    fi

    if [ -n "${fdtdir}" ]; then
        echo "    fdtdir ${fdtdir}" >> "${_EXTLINUX_CONF_TEMP}"
    fi

    if [ -n "${fdtoverlays}" ]; then
        echo "    fdtoverlays ${fdtoverlays}" >> "${_EXTLINUX_CONF_TEMP}"
    fi

    echo "    append ${bootargs}" >> "${_EXTLINUX_CONF_TEMP}"
    echo "" >> "${_EXTLINUX_CONF_TEMP}"

    _NUMBER=$((_NUMBER + 1))
}

# Generate a fingerprint for deduplication (using sha1sum)
# Usage: get_entry_fingerprint board_sanitized
get_entry_fingerprint() {
    local sanitized="$1"
    local name="" kernel="" initrd="" fdtdir="" fdtoverlays="" bootargs=""

    eval "name=\"\${profile_name_${sanitized}}\""
    eval "kernel=\"\${profile_kernel_image_${sanitized}}\""
    eval "initrd=\"\${profile_ramdisk_image_${sanitized}}\""
    eval "fdtdir=\"\${profile_fdtdir_${sanitized}}\""
    eval "fdtoverlays=\"\${profile_fdtoverlays_${sanitized}}\""
    eval "bootargs=\"\${profile_bootargs_${sanitized}}\""

    # Normalize for comparison
    name=$(echo "$name" | xargs)
    fdtoverlays=$(echo "$fdtoverlays" | xargs)
    bootargs=$(echo "$bootargs" | xargs)

    # Create sha1 fingerprint from all content
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$name" "$kernel" "$initrd" "$fdtdir" "$fdtoverlays" "$bootargs" | sha1sum | cut -d' ' -f1
}

# Initialize global fingerprint tracking
# Call this once before processing kernels
init_fingerprint_tracking() {
    _seen_fingerprints=" "
}

# Inject all discovered board entries with deduplication
# Processes default entry first, then board-specific entries
inject_all_entries() {
    local sanitized skip name fingerprint
    local injected_any=""

    # Finalize board names before injection
    finalize_board_names

    # First, process default entry (empty sanitized name)
    eval "skip=\"\${skip_entry_}\""
    eval "name=\"\${profile_name_}\""
    name=$(echo "$name" | xargs)

    if [ -z "$skip" ] && [ -n "$name" ]; then
        fingerprint=$(get_entry_fingerprint "")
        case "${_seen_fingerprints}" in
            *" ${fingerprint} "*)
                [ -z "${_VERBOSE}" ] || echo "P: Skipping duplicate default entry"
                ;;
            *)
                _seen_fingerprints="${_seen_fingerprints}${fingerprint} "
                inject_board_record ""
                injected_any=1
                ;;
        esac
    fi

    # Then process board-specific entries
    for sanitized in ${_discovered_boards}; do
        eval "skip=\"\${skip_entry_${sanitized}}\""
        eval "name=\"\${profile_name_${sanitized}}\""
        name=$(echo "$name" | xargs)

        [ -z "$skip" ] || continue
        [ -n "$name" ] || continue

        # Check for duplicate content
        fingerprint=$(get_entry_fingerprint "$sanitized")
        case "${_seen_fingerprints}" in
            *" ${fingerprint} "*) 
                [ -z "${_VERBOSE}" ] || echo "P: Skipping duplicate entry for board $(get_original_board_name "$sanitized")"
                continue 
                ;;
        esac
        _seen_fingerprints="${_seen_fingerprints}${fingerprint} "

        inject_board_record "$sanitized"
        injected_any=1
    done

    [ -n "$injected_any" ]
}

# Board-aware DTBO discovery and registration
# Usage: add_board_dtbo [-d dtbo_name]... [-n entry_suffix] [-z skip_if_missing] [-e has_default] [-A bootargs]
add_board_dtbo() {
    local dtbo_names=""
    local entry_name=""
    local skip_if_missing=""
    local has_default_entry=""
    local extra_bootargs=""

    OPTIND=1
    while getopts "d:n:zeA:" opt; do
        case "${opt}" in
            d) dtbo_names="${dtbo_names} ${OPTARG}" ;;
            n) entry_name="${OPTARG}" ;;
            z) skip_if_missing=1 ;;
            e) has_default_entry=1 ;;
            A) extra_bootargs="${OPTARG}" ;;
        esac
    done

    local runtime_board=$(get_board_name)
    local boards=""

    if [ -n "${runtime_board}" ]; then
        # Runtime: only process current board
        boards="${runtime_board}"
    else
        # Build time: discover boards from DTBO files
        local found_boards=""
        local fdtdir="${base_fdtdir}${U_BOOT_FDT_VENDOR}/overlay"

        for name in $dtbo_names; do
            [ -d "${fdtdir}" ] || continue

            local paths=$(find "${fdtdir}" -mindepth 2 -maxdepth 2 -name "${name}.dtbo" 2>/dev/null)
            for path in $paths; do
                local rel="${path#${fdtdir}/}"
                local b="${rel%/${name}.dtbo}"
                found_boards="${found_boards} ${b}"
            done
        done

        # Only keep boards that have at least one board-specific DTBO
        # AND are different from just having default dtbos
        local valid_boards=""
        for board in $(echo "${found_boards}" | tr ' ' '\n' | sort -u); do
            [ -n "$board" ] || continue
            
            # Check if this board has any dtbo that differs from default
            # (either board-specific exists and default doesn't, or we just have board-specific)
            local dominated_by_default=1
            for name in $dtbo_names; do
                local board_dtbo="${fdtdir}/${board}/${name}.dtbo"
                local default_dtbo="${fdtdir}/${name}.dtbo"
                
                # If board-specific exists but default doesn't, board is valid
                if [ -e "$board_dtbo" ] && [ ! -e "$default_dtbo" ]; then
                    dominated_by_default=""
                    break
                fi
            done
            
            # Only add board if it's not completely dominated by default
            [ -z "$dominated_by_default" ] && valid_boards="${valid_boards} ${board}"
        done

        boards=$(echo "${valid_boards}" | xargs)
    fi

    # Process each discovered board (only those with unique board-specific DTBOs)
    for board in $boards; do
        local sanitized=$(sanitize_board_name "$board")
        local has_failures=""

        # Register board (initializes variables if new)
        register_board "$board"

        # Try to add all requested DTBOs (board-specific first, then fallback to default)
        for name in $dtbo_names; do
            add_dtbo -b "$board" "${board}/${name}" || add_dtbo -b "$board" "${name}" || has_failures=1
        done

        if [ -n "$has_failures" ] && [ -n "$skip_if_missing" ]; then
            set_skip_entry -b "$board"
        else
            # Only append feature name, not board name (board name added at finalize)
            [ -z "${entry_name}" ] || append_name -b "$board" "[${entry_name}]"
            # Add extra bootargs only to successful boards
            [ -z "$extra_bootargs" ] || add_bootargs -b "$board" "$extra_bootargs"
        fi
    done

    # Handle default entry if applicable
    if [ -n "$has_default_entry" ]; then
        local has_failures=""
        for name in $dtbo_names; do
            add_dtbo "${name}" || has_failures=1
        done

        if [ -n "$has_failures" ] && [ -n "$skip_if_missing" ]; then
            set_skip_entry
        else
            [ -z "${entry_name}" ] || append_name "[${entry_name}]"
            # Add extra bootargs only if default entry is valid
            [ -z "$extra_bootargs" ] || add_bootargs "$extra_bootargs"
        fi
    fi
}

fixup_menu_title() {
    [ "${U_BOOT_MENU_TITLE}" != "${uboot_menu_title}" ] || return 0

    sed -i "s/^menu title .*/$(printf "menu title ${uboot_menu_title}\----------\eE")/" "${_EXTLINUX_CONF_TEMP}"
}

update_config() {
    local target="${1}"
    local source="${2}"

    if [ -e "${target}" ] && cmp -s "${target}" "${source}"; then
        rm -f "${source}"
        return 0
    fi

    echo "P: Generated ${_NUMBER} menu entries in ${target}"
    mv -f "${source}" "${target}"
}
