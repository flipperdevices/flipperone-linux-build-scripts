#!/bin/sh

add_bootargs() {
    local args="$@"
    profile_bootargs="${profile_bootargs:+$profile_bootargs }${args}"
}

remove_bootargs() {
    local args="$@"
    for arg in $args; do
        profile_bootargs="$(echo "${profile_bootargs}" | sed -E "s/(^| )${arg}( |$)/ /g" | xargs)"
    done
}

append_name() {
    local suffix="$@"
    profile_name="${profile_name} ${suffix}"
}

add_legend() {
    local legend="$1"
    local description="$2"
    local no_legend="${processed_legend##*\[$legend\]*}"

    [ -z "${processed_legend}" -o -n "${no_legend}" ] || return 0

    [ "${uboot_menu_title}" != "${U_BOOT_MENU_TITLE}" ] ||
        uboot_menu_title="${uboot_menu_title}\e[0m\/==================\eE"

    uboot_menu_title="${uboot_menu_title}\e[0;38;5;208m - ${legend}\e[0m\e[15G${description}\eE"
    processed_legend="${processed_legend}[${legend}]"
}

set_profile_var() {
    local key="$1"; shift
    local value="$@"
    eval "profile_${key}=${value}"
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

add_dtbo() {
    local dtbo_name="$1"
    local dtbo_file="${dtbo_name}.dtbo"
    local path=""

    [ -n "${profile_fdtdir}" ] || return 1

    path="${profile_fdtdir}/${U_BOOT_FDT_VENDOR}/overlay/${dtbo_file}"
    [ -f "${path}" ] || return 1

    profile_fdtoverlays="${profile_fdtoverlays:+$profile_fdtoverlays }${path}"
}

get_board_name() {
    # Extract board name from device tree
    cat /sys/firmware/devicetree/base/compatible 2>/dev/null | tr '\0' '\n' | awk -F, -vskip_board="${U_BOOT_DT_DETECT_SKIP_BOARD}" '$2 != skip_board { print $2; exit }'
}

inject_record() {
    local profile_id="$1"
    # Append entry to the temporary extlinux.conf
    cat >> "${_EXTLINUX_CONF_TEMP}" <<EOF
label ${profile_id}
    menu label ${profile_name}
    linux ${profile_kernel_image}
EOF

    if [ -n "${profile_ramdisk_image}" ]; then
        echo "    initrd ${profile_ramdisk_image}" >> "${_EXTLINUX_CONF_TEMP}"
    fi

    if [ -n "${profile_fdtdir}" ]; then
        echo "    fdtdir ${profile_fdtdir}" >> "${_EXTLINUX_CONF_TEMP}"
    fi

    if [ -n "${profile_fdtoverlays}" ]; then
        echo "    fdtoverlays ${profile_fdtoverlays}" >> "${_EXTLINUX_CONF_TEMP}"
    fi

    echo "    append ${profile_bootargs}" >> "${_EXTLINUX_CONF_TEMP}"
    echo "" >> "${_EXTLINUX_CONF_TEMP}"
}

add_board_dtbo() {
    local dtbo_names=""
    local entry_name=""
    local do_skip_entry=""
    local has_default_entry=""

    while getopts "d:n:ze" opt; do
        case "${opt}" in
            d) dtbo_names="${dtbo_names} ${OPTARG}" ;;
            n) entry_name="${OPTARG}" ;;
            z) do_skip_entry=1 ;;
            e) has_default_entry=1 ;;
        esac
    done

    local board=$(get_board_name)
    local boards=""
    if [ -n "${board}" ]; then
        boards="${board}"
    else
        # HACK: debos workaround for missing board detection during build
        local found_boards=""
        local fdtdir="${profile_fdtdir}/${U_BOOT_FDT_VENDOR}/overlay"

        # Collect all boards that have at least one of the requested DTBOs
        for name in $dtbo_names; do
            [ -d "${fdtdir}" ] || continue

            # Find dtbo files one level deep (board/name.dtbo)
            local paths=$(find "${fdtdir}" -mindepth 2 -maxdepth 2 -name "${name}.dtbo" 2>/dev/null)
            for path in $paths; do
                local rel="${path#${fdtdir}/}"
                local b="${rel%/${name}.dtbo}"
                found_boards="${found_boards} ${b}"
            done
            [ -e "${fdtdir}/${name}.dtbo" ] && has_default_entry=1
        done

        boards=$(echo "${found_boards}" | tr ' ' '\n' | sort -u | xargs)
    fi

    local orig_profile_fdtoverlays="${profile_fdtoverlays}"
    local orig_profile_name="${profile_name}"

    # Iterate over each board (and default if requested)
    for board in $boards ${has_default_entry:+""}; do
        profile_fdtoverlays="${orig_profile_fdtoverlays}"
        profile_name="${orig_profile_name}"

        local has_failures=""

        # Try to add all requested DTBOs for this board
        for name in $dtbo_names; do
            add_dtbo "${board:+$board/}${name}" || add_dtbo "${name}" ||
                has_failures=1
        done

        # Inject record if we added any overlays, or if it's the default entry (empty board)
        [ -z "${has_failures}" ] || [ -z "${do_skip_entry}" -a -n "${has_default_entry}" -a -z "${board}" ] || continue

        if [ -n "${board}" ] || [ -n "${has_default_entry}" ]; then
            append_name "[${entry_name}${board:+ ($board)}]"
            inject_record "l${_NUMBER}"
            _NUMBER=$((_NUMBER + 1))
        fi
    done

    # We already injected entries, so skip the original one
    skip_entry=1
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
