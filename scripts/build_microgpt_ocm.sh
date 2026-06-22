#!/usr/bin/env bash
# build_microgpt_ocm.sh -- Build TALOS microGPT OCM-only baremetal ELF.
#
# Usage from WSL2:
#   bash /mnt/c/workspace/TALOS-V2/scripts/build_microgpt_ocm.sh
#
# Optional environment overrides:
#   TALOS_BSP_ROOT=/path/to/standalone_a53_0/bsp
#   TALOS_AARCH64_GCC=/path/to/aarch64-none-elf-gcc
#   TALOS_AARCH64_OBJDUMP=/path/to/aarch64-none-elf-objdump

set -euo pipefail

ROOT="${TALOS_ROOT:-/mnt/c/workspace/TALOS-V2}"
APP_SRC="$ROOT/syn/vivado_zcu106/ocm_app/microgpt_ocm_bringup.c"
LINKER_SRC="$ROOT/syn/vivado_zcu106/ocm_app/lscript_ocm.ld"
BUILD_DIR="$ROOT/build/ocm_microgpt"
OUT_ELF="$ROOT/build/microgpt_ocm_bringup.elf"

find_first_dir() {
    for candidate in "$@"; do
        if [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

find_first_exe() {
    for candidate in "$@"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

find_first_bsp() {
    local candidate
    for candidate in \
        "$ROOT/build/vitis_workspace/microgpt_zcu106_platform/psu_cortexa53_0/standalone_a53_0/bsp" \
        "$ROOT/build/vitis_workspace"/*/psu_cortexa53_0/standalone_a53_0/bsp \
        /mnt/c/workspace/TPU/src_tpu_dc/build/vitis_workspace/tpu_zcu106_platform/psu_cortexa53_0/standalone_a53_0/bsp; do
        if [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if [ -n "${TALOS_BSP_ROOT:-}" ]; then
    BSP="$TALOS_BSP_ROOT"
else
    BSP="$(find_first_bsp 2>/dev/null || true)"
fi

if [ -z "${BSP:-}" ] || [ ! -d "$BSP" ]; then
    echo "ERROR: standalone A53 BSP not found." >&2
    echo "Create a Vitis standalone platform from build/vivado_zcu106/microgpt_zcu106.xsa, or set TALOS_BSP_ROOT." >&2
    exit 1
fi

if [ -n "${TALOS_AARCH64_GCC:-}" ]; then
    CC="$TALOS_AARCH64_GCC"
else
    CC="$(find_first_exe \
        /opt/Xilinx/2025.2/Vitis/gnu/aarch64/lin/aarch64-none/bin/aarch64-none-elf-gcc \
        /opt/Xilinx/Vitis/gnu/aarch64/lin/aarch64-none/bin/aarch64-none-elf-gcc \
        /opt/Xilinx/Vitis/Vitis/gnu/aarch64/lin/aarch64-none/bin/aarch64-none-elf-gcc \
        2>/dev/null || true)"
fi

if [ -z "${CC:-}" ] || [ ! -x "$CC" ]; then
    echo "ERROR: aarch64-none-elf-gcc not found. Set TALOS_AARCH64_GCC." >&2
    exit 1
fi

if [ -n "${TALOS_AARCH64_OBJDUMP:-}" ]; then
    OBJDUMP="$TALOS_AARCH64_OBJDUMP"
else
    OBJDUMP="${CC%-gcc}-objdump"
fi

if [ ! -x "$OBJDUMP" ]; then
    echo "ERROR: aarch64-none-elf-objdump not found. Set TALOS_AARCH64_OBJDUMP." >&2
    exit 1
fi

mkdir -p "$BUILD_DIR" "$ROOT/build"
cp "$LINKER_SRC" "$BUILD_DIR/lscript.ld"
cd "$BUILD_DIR"

COMMON_FLAGS=(
    -DSDT
    -MMD
    -MP
    -specs="$BSP/Xilinx.spec"
    -I"$BSP/include"
    -Wall
    -Wextra
    -O0
    -g3
    -U__clang__
)

"$CC" "${COMMON_FLAGS[@]}" -c "$APP_SRC" -o microgpt_ocm_bringup.o

"$CC" "${COMMON_FLAGS[@]}" microgpt_ocm_bringup.o -o microgpt_ocm_bringup.elf \
    -Wl,-T -Wl,"$BUILD_DIR/lscript.ld" \
    -L"$BSP/lib" \
    -Wl,--start-group -lxilstandalone -lxiltimer -lxil -lgcc -lc -Wl,--end-group

cp microgpt_ocm_bringup.elf "$OUT_ELF"

"$OBJDUMP" -f "$OUT_ELF"
"$OBJDUMP" -h "$OUT_ELF" | grep -E 'Idx|\.text|\.data|\.bss|\.stack|\.mmu_tbl|\.heap'
"$OBJDUMP" -t "$OUT_ELF" | grep -E '_vector_table|_boot|__el3_stack|\*UND\*.*(_start|_vector_table|_boot)' || true

echo ""
echo "Built: $OUT_ELF"

