# Board Configuration Files

This directory contains board-specific configuration files for all supported RK3576 boards.

## Quick Reference

Use the board-config utility to manage and view configurations:

```bash
# List all boards
../board-config.sh list

# Show detailed configuration for a board
../board-config.sh show rock-4d

# Validate all configurations
../board-config.sh validate

# Get a specific value
../board-config.sh get sige5 UBOOT_GIT
```

## Configuration Format

Each board has a `.conf` file that defines:

### Basic Information
- `BOARD_NAME`: Short board identifier used in build scripts
- `BOARD_FULL_NAME`: Full human-readable board name
- `BOARD_VENDOR`: Manufacturer name
- `BOARD_SOC`: System-on-Chip (always "rk3576" for this project)

### U-Boot Settings
- `UBOOT_DEFCONFIG`: U-Boot defconfig file name (e.g., `rock-4d-rk3576_defconfig`)
- `UBOOT_GIT`: Git repository URL for U-Boot source
- `UBOOT_BRANCH`: Git branch to use

### ARM Trusted Firmware
- `USE_BL31`: Either "opensource" for TF-A or "vendor" for Rockchip binary BL31

### Device Tree Configuration
- `DTS_VENDOR_DIR`: Subdirectory in vendor-dts/ containing board-specific DTS files
- `DTS_BASE`: Base device tree file name (if applicable)
- `DTS_OVERLAYS`: Space-separated list of available overlay files (if applicable)

### Storage Support
- `SUPPORTS_EMMC`: Boolean (true/false)
- `SUPPORTS_SD`: Boolean (true/false)
- `SUPPORTS_UFS`: Boolean (true/false)
- `SUPPORTS_SPI_FLASH`: Boolean (true/false)

### Maskrom Mode
- `MASKROM_BUTTON`: Which button to hold for Maskrom mode
- `MASKROM_USB_PORT`: Which USB port to use for flashing
- `MASKROM_NOTES`: Additional Maskrom-specific notes

### Additional Information
- `BOARD_NOTES`: General notes about the board
- `UPSTREAM_SUPPORT`: Boolean - whether board is in upstream U-Boot
- `REFERENCE_BOARD`: Boolean - whether this is a reference design

## Usage

Build scripts can source these files to get board-specific settings:

```bash
# Load board configuration
BOARD_CONFIG="configs/boards/${BOARD}.conf"
if [ -f "$BOARD_CONFIG" ]; then
    source "$BOARD_CONFIG"
fi
```

## Supported Boards

| Board Name | Vendor | Full Name | Upstream Support |
|------------|--------|-----------|------------------|
| rock-4d | Radxa | Radxa Rock 4D | No |
| sige5 | ArmSoM | ArmSoM Sige5 | No |
| omni3576 | Luckfox | Luckfox Omni3576 | No |
| nanopi-m5 | FriendlyElec | FriendlyElec NanoPi M5 | No |
| roc-rk3576-pc | Firefly | Firefly ROC-RK3576-PC | Yes |
| rk3576-evb1-v10 | Rockchip | Rockchip RK3576 EVB1 v1.0 | No (Reference) |

## Adding a New Board

1. Create a new `.conf` file named `<board-name>.conf`
2. Fill in all required configuration variables
3. Add appropriate U-Boot defconfig to U-Boot source tree
4. Add device tree files to `vendor-dts/` if needed
5. Update this README with the new board information
