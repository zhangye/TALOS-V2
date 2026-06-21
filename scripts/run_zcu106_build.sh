#!/usr/bin/env bash
# ============================================================================
# run_zcu106_build.sh — 一键构建 + 自动提取测试报告
# ============================================================================
# 用法:
#   bash scripts/run_zcu106_build.sh
#
# 前置条件:
#   - Xilinx Vivado 2025.2 已安装
#   - vivado 命令在 PATH 中 (或设置 VIVADO_ROOT)
#
# 产出:
#   build/microgpt_zcu106.bit          比特流
#   build/vivado_zcu106/microgpt_zcu106.xsa  硬件平台
#   build/zcu106_*.rpt                 Vivado 报告
#   build/test_report.txt              自动提取的测试报告
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
REPORT="${BUILD_DIR}/test_report.txt"

# ── 查找 Vivado ──
if [ -n "$VIVADO_ROOT" ]; then
    VIVADO="${VIVADO_ROOT}/bin/vivado"
elif command -v vivado &>/dev/null; then
    VIVADO="$(command -v vivado)"
else
    # 常见默认路径
    for p in /opt/Xilinx/Vivado/2025.2/bin/vivado \
             /tools/Xilinx/Vivado/2025.2/bin/vivado \
             "C:/Xilinx/Vivado/2025.2/bin/vivado.bat"; do
        if [ -x "$p" ]; then VIVADO="$p"; break; fi
    done
fi

if [ -z "$VIVADO" ] || [ ! -x "$VIVADO" ]; then
    echo "ERROR: vivado not found. Set VIVADO_ROOT or add to PATH."
    exit 1
fi

echo "============================================"
echo " TALOS-V2 ZCU106 Build & Test"
echo " Vivado: ${VIVADO}"
echo " Project: ${PROJECT_ROOT}"
echo "============================================"

mkdir -p "${BUILD_DIR}"

# ── Step 1: Vivado 构建 ──
echo ""
echo "[Step 1/3] Running Vivado build..."
BUILD_START=$(date +%s)

if "${VIVADO}" -mode batch -nolog -nojournal \
    -source "${SCRIPT_DIR}/vivado_zcu106.tcl" \
    -log "${BUILD_DIR}/vivado_build.log" \
    -journal "${BUILD_DIR}/vivado_build.jou"; then
    BUILD_OK=1
else
    BUILD_OK=0
fi

BUILD_END=$(date +%s)
BUILD_SECS=$((BUILD_END - BUILD_START))

echo "  Build took ${BUILD_SECS} seconds"

# ── Step 2: 提取报告 ──
echo ""
echo "[Step 2/3] Extracting reports..."

{
    echo "========================================================"
    echo " TALOS-V2 ZCU106 测试报告"
    echo " 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo " 构建耗时: ${BUILD_SECS} 秒"
    echo "========================================================"
    echo ""

    # 构建状态
    echo "── 1. 构建状态 ──"
    if [ "${BUILD_OK}" -eq 1 ] && [ -f "${BUILD_DIR}/microgpt_zcu106.bit" ]; then
        BIT_SIZE=$(stat -c%s "${BUILD_DIR}/microgpt_zcu106.bit" 2>/dev/null || stat -f%z "${BUILD_DIR}/microgpt_zcu106.bit" 2>/dev/null || echo "unknown")
        echo "  状态: ✅ 成功"
        echo "  比特流: build/microgpt_zcu106.bit (${BIT_SIZE} bytes)"
        if [ -f "${BUILD_DIR}/vivado_zcu106/microgpt_zcu106.xsa" ]; then
            XSA_SIZE=$(stat -c%s "${BUILD_DIR}/vivado_zcu106/microgpt_zcu106.xsa" 2>/dev/null || echo "unknown")
            echo "  XSA: build/vivado_zcu106/microgpt_zcu106.xsa (${XSA_SIZE} bytes)"
        fi
    else
        echo "  状态: ❌ 失败"
        if [ -f "${BUILD_DIR}/vivado_build.log" ]; then
            echo "  日志: build/vivado_build.log"
            # 提取最后 10 行错误
            echo "  最后错误:"
            grep -i "error\|fatal\|failed" "${BUILD_DIR}/vivado_build.log" | tail -5 | sed 's/^/    /'
        fi
    fi
    echo ""

    # 综合利用率
    echo "── 2. 综合资源利用率 ──"
    SYNTH_UTIL="${BUILD_DIR}/zcu106_synth_util.rpt"
    if [ -f "${SYNTH_UTIL}" ]; then
        # 提取关键资源
        grep -A 1 "CLB LUTs\|CLB Registers\|Block RAM\|DSP" "${SYNTH_UTIL}" | \
            grep "|" | head -8 | sed 's/^/  /'
    else
        echo "  (报告未生成)"
    fi
    echo ""

    # 实现利用率
    echo "── 3. 实现资源利用率 ──"
    IMPL_UTIL="${BUILD_DIR}/zcu106_impl_util.rpt"
    if [ -f "${IMPL_UTIL}" ]; then
        echo "  CLB LUTs:"
        grep "CLB LUTs" "${IMPL_UTIL}" | head -1 | sed 's/^/    /'
        echo "  CLB Registers:"
        grep "CLB Registers" "${IMPL_UTIL}" | head -1 | sed 's/^/    /'
        echo "  DSP48E2:"
        grep "DSP" "${IMPL_UTIL}" | head -1 | sed 's/^/    /'
        echo "  BRAM:"
        grep -i "Block RAM\|BRAM" "${IMPL_UTIL}" | head -1 | sed 's/^/    /'
    else
        echo "  (报告未生成)"
    fi
    echo ""

    # 时序
    echo "── 4. 时序 ──"
    IMPL_TIMING="${BUILD_DIR}/zcu106_impl_timing_summary.rpt"
    if [ -f "${IMPL_TIMING}" ]; then
        grep -i "WNS\|WHS\|WPWS\|Design Timing Summary" "${IMPL_TIMING}" | head -5 | sed 's/^/  /'
    else
        echo "  (报告未生成)"
    fi
    # 从 Vivado 日志提取门禁结果
    if [ -f "${BUILD_DIR}/vivado_build.log" ]; then
        echo "  门禁检查:"
        grep -i "Timing OK\|WNS =\|LUT.*%\|threshold\|ERROR.*LUT\|ERROR.*Timing" \
            "${BUILD_DIR}/vivado_build.log" | sed 's/^/    /'
    fi
    echo ""

    # 功耗
    echo "── 5. 功耗 ──"
    IMPL_POWER="${BUILD_DIR}/zcu106_impl_power.rpt"
    if [ -f "${IMPL_POWER}" ]; then
        grep -i "Total On-Chip Power\|Dynamic\|Static\|Junction" "${IMPL_POWER}" | head -4 | sed 's/^/  /'
    else
        echo "  (报告未生成)"
    fi
    echo ""

    # 门禁结果
    echo "── 6. 门禁检查汇总 ──"
    if [ "${BUILD_OK}" -eq 1 ] && [ -f "${BUILD_DIR}/microgpt_zcu106.bit" ]; then
        echo "  ✅ 综合: 通过"
        echo "  ✅ 实现: 通过"
        echo "  ✅ 比特流: 生成成功"
        # 检查 WNS
        if [ -f "${IMPL_TIMING}" ]; then
            WNS_VAL=$(grep "WNS" "${IMPL_TIMING}" | head -1 | grep -oP '[-\d.]+(?=\s+ns)' | head -1)
            if [ -n "${WNS_VAL}" ]; then
                if echo "${WNS_VAL}" | grep -q "^-"; then
                    echo "  ❌ 时序: WNS=${WNS_VAL}ns (违规!)"
                else
                    echo "  ✅ 时序: WNS=${WNS_VAL}ns (正裕量)"
                fi
            fi
        fi
    else
        echo "  ❌ 构建未完成"
    fi
    echo ""

    echo "========================================================"
    echo " 下一步: 烧录到 ZCU106"
    echo "   xsdb syn/vivado_zcu106/download_microgpt.tcl"
    echo "========================================================"

} > "${REPORT}"

echo "  测试报告: ${REPORT}"

# ── Step 3: 打印报告摘要 ──
echo ""
echo "[Step 3/3] Report summary:"
echo ""
cat "${REPORT}"
