#!/bin/sh
set -e

KERNEL_DIR="$1"
SRC="$2"
OUTDIR="$3"
BASEDTB="$4"
OUTFILE="$OUTDIR/$(basename "${SRC%.*}.dtbo")"

if [ ! -d "$KERNEL_DIR" ]; then
    echo "Error: Kernel directory $KERNEL_DIR not found."
    exit 1
fi

mkdir -p "$OUTDIR"
echo "Compiling $SRC..."

# 1. Preprocess with CPP
#    -nostdinc: Do not search standard system directories
#    -undef: Do not predefine system-specific macros
#    -x assembler-with-cpp: Treat input as assembly (preserves comments/structure better for DTC)
cpp -nostdinc \
    -I "$KERNEL_DIR/include" \
    -I "$KERNEL_DIR/arch/arm64/boot/dts" \
    -undef -x assembler-with-cpp \
    "$SRC" |

# 2. Compile with DTC
#    -@: Enable generation of __fixups__ and __symbols__. 
#        This is CRITICAL for overlays to resolve references (like &dsi) 
#        against the base DTB at runtime.
dtc -@ -I dts -O dtb -o "$OUTFILE"

echo "Success: Generated $OUTFILE"

# 3. Validate overlay symbols against base DTB if provided
if [ -n "$BASEDTB" ] && [ -f "$BASEDTB" ]; then
    echo "Validating symbols against base DTB: $BASEDTB"
    
    overlay_refs_file=$(mktemp)
    base_symbols_file=$(mktemp)
    trap "rm -f '$overlay_refs_file' '$base_symbols_file'" INT EXIT

    # Extract __fixups__ from the overlay (references to base DTB symbols)
    fdtget -p "$OUTFILE" "/__fixups__" | sort -u > "$overlay_refs_file"
    
    # Get symbols from base DTB
    fdtget -p "$BASEDTB" "/__symbols__" | sort -u > "$base_symbols_file"
    
    # Find symbols referenced by overlay but missing in base
    # comm -23: lines unique to file1 (overlay refs not in base symbols)
    missing=$(comm -23 "$overlay_refs_file" "$base_symbols_file")
    
    if [ -n "$missing" ]; then
        echo "ERROR: Overlay references symbols not present in base DTB:"
        echo "$missing" | sed 's/^/  - /'
        exit 1
    else
        echo "All overlay symbols validated successfully."
    fi
fi
