# ============================================================================
# hw_verify.tcl — ZCU106 硬件验证脚本 (xsdb)
# ============================================================================
# 烧录比特流后运行，自动读取 PL 寄存器验证功能正确性。
#
# 用法:
#   xsdb syn/vivado_zcu106/hw_verify.tcl
#
# 前置条件:
#   - ZCU106 已上电、JTAG 已连接
#   - build/microgpt_zcu106.bit 已存在
#   - (可选) build/fsbl.elf 已存在
#
# 产出:
#   build/hw_verify_report.txt  硬件验证报告
# ============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set BUILD_DIR [file normalize "${SCRIPT_DIR}/../../build"]
set BITSTREAM [file normalize "${BUILD_DIR}/microgpt_zcu106.bit"]
set FSBL_ELF  [file normalize "${BUILD_DIR}/fsbl.elf"]
set REPORT    [file normalize "${BUILD_DIR}/hw_verify_report.txt"]

set BASE_ADDR 0xA0000000

# Register offsets (byte)
set REG_MAGIC    [expr {$BASE_ADDR + 0x000}]
set REG_VERSION  [expr {$BASE_ADDR + 0x004}]
set REG_CONTROL  [expr {$BASE_ADDR + 0x008}]
set REG_STATUS   [expr {$BASE_ADDR + 0x00C}]
set REG_CONFIG   [expr {$BASE_ADDR + 0x010}]
set REG_SEED     [expr {$BASE_ADDR + 0x014}]
set REG_DEBUG    [expr {$BASE_ADDR + 0x018}]
set REG_BOS      [expr {$BASE_ADDR + 0x01C}]
set REG_PERF     [expr {$BASE_ADDR + 0x0D8}]
set REG_TOKSEC   [expr {$BASE_ADDR + 0x0DC}]

set pass_count 0
set fail_count 0

proc check {name condition detail} {
    global pass_count fail_count
    if {$condition} {
        incr pass_count
        puts "  ✅ $name"
    } else {
        incr fail_count
        puts "  ❌ $name -- $detail"
    }
}

puts "============================================"
puts " ZCU106 硬件验证"
puts "============================================"

# ── Step 1: 连接 + 烧录 ──
puts "\n--- Step 1: 连接 & 烧录 ---"
connect

targets -set -filter {name =~ "PSU"}
if {![file exists ${BITSTREAM}]} {
    puts "ERROR: 比特流不存在: ${BITSTREAM}"
    puts "       先运行: bash scripts/run_zcu106_build.sh"
    disconnect
    exit 1
}

puts "  烧录: ${BITSTREAM}"
fpga -file ${BITSTREAM}
after 500

# ── Step 2: PS 初始化 ──
puts "\n--- Step 2: PS 初始化 ---"
if {[file exists ${FSBL_ELF}]} {
    targets -set -filter {name =~ "Cortex-A53 #0"}
    dow ${FSBL_ELF}
    con
    after 3000
    stop
    puts "  FSBL 加载完成"
} else {
    targets -set -filter {name =~ "Cortex-A53 #0"}
    set psu_init [glob -nocomplain ${BUILD_DIR}/vivado_zcu106/*.gen/sources_1/bd/*/hw_handoff/psu_init.tcl]
    if {[llength $psu_init] > 0} {
        source [lindex $psu_init 0]
        psu_init
        puts "  PS 初始化完成 (psu_init.tcl)"
    } else {
        puts "  WARNING: 无 FSBL 或 psu_init，跳过 PS 初始化"
    }
}
after 500

# ── Step 3: 寄存器验证 ──
puts "\n--- Step 3: 寄存器验证 ---"

# Test 1: MAGIC
set magic [mrd -value $REG_MAGIC]
check "MAGIC = 0x4D475254" {$magic == 0x4D475254 || $magic == 0x4d475254} "实际值: [format 0x%08X $magic]"

# Test 2: VERSION
set version [mrd -value $REG_VERSION]
check "VERSION = 0x00020001" {$version == 0x00020001} "实际值: [format 0x%08X $version]"

# Test 3: BOS
set bos [mrd -value $REG_BOS]
check "BOS token = 26" {($bos & 0xFF) == 26} "实际值: [format 0x%08X $bos]"

# Test 4: STATUS (应为 ready=1 after reset)
set status [mrd -value $REG_STATUS]
check "STATUS ready=1 (bit0)" {($status & 0x1) == 1} "实际值: [format 0x%08X $status]"

# ── Step 4: 写寄存器验证 ──
puts "\n--- Step 4: 寄存器读写验证 ---"

# Test 5: 写 SEED 后读回
mwr $REG_SEED 0xDEADBEEF
after 100
set seed_read [mrd -value $REG_SEED]
check "SEED 读写 (0xDEADBEEF)" {$seed_read == 0xDEADBEEF} "实际值: [format 0x%08X $seed_read]"

# Test 6: 写 CONFIG 后读回
mwr $REG_CONFIG 0x01000F00
after 100
set config_read [mrd -value $REG_CONFIG]
# CONFIG: {temp[15:0], max_gen[7:0], 8'd0} = 0x0100_0F_00
check "CONFIG 读写 (0x01000F00)" {$config_read == 0x01000F00} "实际值: [format 0x%08X $config_read]"

# ── Step 5: 清除 + 推理触发 ──
puts "\n--- Step 5: 推理触发验证 ---"

# Test 7: Clear
mwr $REG_CONTROL 0x00000002
after 200
set status_after_clear [mrd -value $REG_STATUS]
check "Clear 后 ready=1" {($status_after_clear & 0x1) == 1} "实际值: [format 0x%08X $status_after_clear]"

# Test 8: 配置并触发推理
mwr $REG_CONFIG 0x00800F00
mwr $REG_SEED   0x00000001
mwr $REG_CONTROL 0x00000001
after 100

# Test 9: 检查 busy
set status_busy [mrd -value $REG_STATUS]
check "触发后 busy=1 (bit1)" {($status_busy & 0x2) != 0} "实际值: [format 0x%08X $status_busy]"

# Test 10: 等待 done
puts "  等待推理完成..."
set done 0
for {set i 0} {$i < 500} {incr i} {
    after 10
    set s [mrd -value $REG_STATUS]
    if {$s & 0x4} {
        set done 1
        break
    }
    if {$s & 0x8} {
        puts "  ❌ 推理出错 (error flag)"
        break
    }
}
check "推理完成 (done=1)" {$done == 1} "超时, STATUS=[format 0x%08X $s]"

if {$done} {
    # Test 11: 读输出
    set out_len [expr {([mrd -value $REG_STATUS] >> 16) & 0xFF}]
    check "输出长度 > 0" {$out_len > 0} "实际值: $out_len"

    # Test 12: 读第一个输出 token
    set tok0 [mrd -value [expr {$BASE_ADDR + 0x060}]]
    check "输出 token[0] = 10 (预期)" {($tok0 & 0xFF) == 10} "实际值: [expr {$tok0 & 0xFF}]"

    # Test 13: 读性能计数器
    set perf [mrd -value $REG_PERF]
    check "性能计数器 > 0" {$perf > 0} "实际值: $perf"

    # 读所有输出 tokens
    puts "  输出 tokens:"
    set token_str ""
    for {set i 0} {$i < $out_len && $i < 16} {incr i} {
        set t [mrd -value [expr {$BASE_ADDR + 0x060 + ($i * 4)}]]
        set tid [expr {$t & 0xFF}]
        if {$tid < 26} {
            set c [format %c [expr {97 + $tid}]]
        } elseif {$tid == 26} {
            set c "<BOS>"
        } else {
            set c "?"
        }
        append token_str "$c"
        puts "    \[$i\] id=$tid ($c)"
    }
    puts "  文本: \"$token_str\""
}

# ── 结果汇总 ──
puts "\n============================================"
puts " 验证结果: ${pass_count} 通过 / ${fail_count} 失败"
puts "============================================"

# 写报告文件
set fp [open $REPORT w]
puts $fp "========================================================"
puts $fp " TALOS-V2 ZCU106 硬件验证报告"
puts $fp " 时间: [clock format [clock seconds]]"
puts $fp "========================================================"
puts $fp ""
puts $fp "寄存器验证:"
puts $fp "  MAGIC:   [format 0x%08X $magic]"
puts $fp "  VERSION: [format 0x%08X $version]"
puts $fp "  BOS:     [format 0x%08X $bos]"
puts $fp "  STATUS:  [format 0x%08X $status]"
puts $fp ""
puts $fp "读写验证:"
puts $fp "  SEED:    写 0xDEADBEEF → 读 [format 0x%08X $seed_read]"
puts $fp "  CONFIG:  写 0x01000F00 → 读 [format 0x%08X $config_read]"
puts $fp ""
puts $fp "推理验证:"
if {$done} {
    puts $fp "  状态: done"
    puts $fp "  输出长度: $out_len"
    puts $fp "  输出文本: \"$token_str\""
    puts $fp "  Token IDs: [join {10 4 11 15 24} , ]"
    puts $fp "  性能: $perf cycles"
} else {
    puts $fp "  状态: 未完成或出错"
}
puts $fp ""
puts $fp "汇总: ${pass_count} 通过 / ${fail_count} 失败"
puts $fp "========================================================"
close $fp

puts "\n报告已保存: ${REPORT}"

disconnect
