#!/bin/bash
# Board configuration management utility

BOARDS_CONFIG_DIR="$(dirname "$0")/boards"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

show_usage() {
    cat <<EOF
Usage: $0 [COMMAND] [BOARD]

Board configuration management utility for RK3576 boards.

Commands:
    list                List all available boards
    show BOARD          Show configuration for a specific board
    validate [BOARD]    Validate board configuration(s)
    get BOARD KEY       Get a specific configuration value
    help                Show this help message

Examples:
    $0 list
    $0 show rock-4d
    $0 validate
    $0 get sige5 UBOOT_GIT

EOF
}

list_boards() {
    echo -e "${BLUE}Available boards:${NC}"
    echo ""
    printf "%-20s %-15s %-35s\n" "BOARD NAME" "VENDOR" "FULL NAME"
    printf "%-20s %-15s %-35s\n" "----------" "------" "---------"

    for conf in "$BOARDS_CONFIG_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        unset BOARD_NAME BOARD_VENDOR BOARD_FULL_NAME
        source "$conf"
        printf "%-20s %-15s %-35s\n" "$BOARD_NAME" "$BOARD_VENDOR" "$BOARD_FULL_NAME"
    done
}

show_board() {
    local board="$1"
    local conf="$BOARDS_CONFIG_DIR/${board}.conf"

    if [ ! -f "$conf" ]; then
        echo -e "${RED}Error: Board configuration not found: $board${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}Configuration for: $board${NC}"
    echo ""

    source "$conf"

    cat <<EOF
Board Information:
  Name:              $BOARD_NAME
  Full Name:         $BOARD_FULL_NAME
  Vendor:            $BOARD_VENDOR
  SoC:               $BOARD_SOC

U-Boot Configuration:
  Defconfig:         $UBOOT_DEFCONFIG
  Git Repository:    $UBOOT_GIT
  Branch:            $UBOOT_BRANCH

ARM Trusted Firmware:
  BL31 Type:         $USE_BL31

Device Tree:
  Vendor Directory:  $DTS_VENDOR_DIR
  Base DTS:          ${DTS_BASE:-N/A}
  Overlays:          ${DTS_OVERLAYS:-N/A}

Storage Support:
  eMMC:              ${SUPPORTS_EMMC:-false}
  SD Card:           ${SUPPORTS_SD:-false}
  UFS:               ${SUPPORTS_UFS:-false}
  SPI Flash:         ${SUPPORTS_SPI_FLASH:-false}

Maskrom Configuration:
  Button:            ${MASKROM_BUTTON:-N/A}
  USB Port:          ${MASKROM_USB_PORT:-N/A}
  Notes:             ${MASKROM_NOTES:-N/A}

Additional:
  Notes:             ${BOARD_NOTES:-N/A}
  Upstream Support:  ${UPSTREAM_SUPPORT:-false}
  Reference Board:   ${REFERENCE_BOARD:-false}
EOF
}

validate_board() {
    local conf="$1"
    local board=$(basename "$conf" .conf)
    local errors=0

    source "$conf"

    # Required fields
    local required_vars=(
        "BOARD_NAME"
        "BOARD_FULL_NAME"
        "BOARD_VENDOR"
        "BOARD_SOC"
        "UBOOT_DEFCONFIG"
        "UBOOT_GIT"
        "UBOOT_BRANCH"
        "USE_BL31"
    )

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo -e "  ${RED}✗${NC} Missing required variable: $var"
            ((errors++))
        fi
    done

    # Validate USE_BL31
    if [ -n "$USE_BL31" ] && [ "$USE_BL31" != "opensource" ] && [ "$USE_BL31" != "vendor" ]; then
        echo -e "  ${RED}✗${NC} Invalid USE_BL31 value: $USE_BL31 (must be 'opensource' or 'vendor')"
        ((errors++))
    fi

    # Validate boolean fields if present
    local bool_vars=(
        "SUPPORTS_EMMC"
        "SUPPORTS_SD"
        "SUPPORTS_UFS"
        "SUPPORTS_SPI_FLASH"
        "UPSTREAM_SUPPORT"
        "REFERENCE_BOARD"
    )

    for var in "${bool_vars[@]}"; do
        if [ -n "${!var}" ] && [ "${!var}" != "true" ] && [ "${!var}" != "false" ]; then
            echo -e "  ${YELLOW}⚠${NC} Warning: $var should be 'true' or 'false', got: ${!var}"
        fi
    done

    if [ $errors -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} Valid configuration"
        return 0
    else
        echo -e "  ${RED}✗${NC} $errors error(s) found"
        return 1
    fi
}

validate_all() {
    echo -e "${BLUE}Validating board configurations...${NC}"
    echo ""

    local total=0
    local failed=0

    for conf in "$BOARDS_CONFIG_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        ((total++))

        board=$(basename "$conf" .conf)
        echo "Checking $board:"

        if ! validate_board "$conf"; then
            ((failed++))
        fi
        echo ""
    done

    echo "----------------------------------------"
    echo -e "Total: $total  ${GREEN}Passed: $((total - failed))${NC}  ${RED}Failed: $failed${NC}"

    return $failed
}

get_value() {
    local board="$1"
    local key="$2"
    local conf="$BOARDS_CONFIG_DIR/${board}.conf"

    if [ ! -f "$conf" ]; then
        echo -e "${RED}Error: Board configuration not found: $board${NC}" >&2
        return 1
    fi

    source "$conf"
    echo "${!key}"
}

# Main command dispatcher
case "${1:-help}" in
    list)
        list_boards
        ;;
    show)
        if [ -z "$2" ]; then
            echo -e "${RED}Error: Board name required${NC}" >&2
            show_usage
            exit 1
        fi
        show_board "$2"
        ;;
    validate)
        if [ -n "$2" ]; then
            validate_board "$BOARDS_CONFIG_DIR/$2.conf"
        else
            validate_all
        fi
        ;;
    get)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo -e "${RED}Error: Board name and key required${NC}" >&2
            show_usage
            exit 1
        fi
        get_value "$2" "$3"
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command: $1${NC}" >&2
        echo ""
        show_usage
        exit 1
        ;;
esac
