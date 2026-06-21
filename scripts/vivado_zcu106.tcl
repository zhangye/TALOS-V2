# ============================================================================
# vivado_zcu106.tcl -- Vivado Block Design: Zynq PS + microGPT PL (ZCU106)
# ============================================================================
# Creates a Vivado Block Design with:
#   - Zynq UltraScale+ PS (board preset for ZCU106)
#   - SmartConnect (PS M_AXI_HPM0_FPD -> microGPT S_AXI)
#   - microgpt_top_fpga wrapper (AXI4-Lite slave)
#   - IRQ connected to PS pl_ps_irq0
#
# Output:
#   build/vivado_zcu106/microgpt_zcu106.xsa   (hardware platform with bitstream)
#   build/vivado_zcu106/microgpt_zcu106.bit   (bitstream)
#   build/zcu106_synth_*.rpt                   (synthesis reports)
#   build/zcu106_impl_*.rpt                    (implementation reports)
#
# Usage (from Vivado Tcl Shell):
#   vivado -mode batch -nolog -nojournal -source scripts/vivado_zcu106.tcl
#
# Revision: 2026-06-21
# ============================================================================

# ============================================================================
# Configuration
# ============================================================================
set PART "xczu7ev-ffvc1156-2-e"
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set RTL_DIR [file normalize "${SCRIPT_DIR}/../rtl/src"]
set WRAPPER_FILE [file normalize "${SCRIPT_DIR}/../syn/vivado_zcu106/microgpt_top_fpga.v"]
set OUT_DIR [file normalize "${SCRIPT_DIR}/../build"]
set PROJ_DIR [file normalize "${OUT_DIR}/vivado_zcu106"]

file mkdir ${OUT_DIR}
file mkdir ${PROJ_DIR}

puts "============================================================"
puts " Vivado PS+PL Block Design -- Zynq PS + microGPT (ZCU106)"
puts " Part:     ${PART}"
puts " RTL:      ${RTL_DIR}"
puts " Wrapper:  ${WRAPPER_FILE}"
puts " Output:   ${PROJ_DIR}"
puts "============================================================"

# ============================================================================
# 1. Create Project
# ============================================================================
create_project microgpt_zcu106 ${PROJ_DIR} -part ${PART} -force
set_property target_language Verilog [current_project]
set_property BOARD_PART xilinx.com:zcu106:part0:2.6 [current_project]

puts "--- Project created ---"

# ============================================================================
# 2. Add RTL Source Files
# ============================================================================
puts "--- Adding RTL sources ---"

# Set include directory for .svh files
set_property include_dirs ${RTL_DIR}/include [current_fileset]

# Include files (must be added to project explicitly for BD module reference)
read_verilog -sv ${RTL_DIR}/include/microgpt_exact_core_params.svh
read_verilog -sv ${RTL_DIR}/include/microgpt_exact_core_math.svh
read_verilog -sv ${RTL_DIR}/include/microgpt_exact_core_rom_init.svh

# Core inference engine (platform-agnostic SystemVerilog)
read_verilog -sv ${RTL_DIR}/microgpt_exact_core.sv

# Sub-modules
read_verilog -sv ${RTL_DIR}/systolic_matvec16_tile.sv
read_verilog -sv ${RTL_DIR}/rms_scale_engine.sv
read_verilog -sv ${RTL_DIR}/sat_div16_engine.sv
read_verilog -sv ${RTL_DIR}/microgpt_categorical_sampler.sv

# FPGA Wrapper (Verilog-2001 for BD module reference compatibility)
add_files ${WRAPPER_FILE}

puts "--- 9 source files added (3 svh + 5 RTL + 1 wrapper) ---"

# $readmemh paths in microgpt_exact_core_rom_init.svh are relative:
#   "generated/wte_q12.hex"
# Vivado resolves these relative to the INCLUDING file's directory (rtl/src/).
# Create rtl/src/generated/ -> symlink/copy of rtl/generated/ so paths resolve.
set HEX_SRC [file normalize "${SCRIPT_DIR}/../rtl/generated"]
set HEX_DST [file normalize "${RTL_DIR}/generated"]
if {[file exists ${HEX_SRC}]} {
    if {![file exists ${HEX_DST}]} {
        if {$tcl_platform(platform) eq "windows"} {
            # Windows: copy files (symlinks need admin)
            file mkdir ${HEX_DST}
            foreach f [glob -nocomplain ${HEX_SRC}/*.hex] {
                file copy -force $f ${HEX_DST}/
            }
            puts "--- Hex files copied to ${HEX_DST} ---"
        } else {
            # Linux/macOS: symlink
            file link -symbolic ${HEX_DST} ${HEX_SRC}
            puts "--- Symlinked ${HEX_DST} -> ${HEX_SRC} ---"
        }
    }
} else {
    puts "WARNING: ROM hex directory not found: ${HEX_SRC}"
    puts "         \$readmemh will fail at elaboration time."
}

# ============================================================================
# 3. Create Block Design
# ============================================================================
puts "============================================================"
puts " Creating Block Design..."
puts "============================================================"

create_bd_design "design_1"

# --- 3a. Add Zynq UltraScale+ MPSoC ---
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0

# Apply ZCU106 board preset (configures DDR4, UART, clocks, MIO, etc.)
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]

puts "--- Zynq PS configured ---"

# --- 3b. Add microGPT PL Wrapper as RTL Module ---
create_bd_cell -type module -reference microgpt_top_fpga microgpt_top_fpga_0

puts "--- microGPT wrapper added to block design ---"

# --- 3c. Connect PS -> microGPT via SmartConnect ---
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0
set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {1} \
] [get_bd_cells smartconnect_0]

# PS M_AXI_HPM0_FPD -> SmartConnect S00_AXI
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins smartconnect_0/S00_AXI]

# SmartConnect M00_AXI -> microGPT S_AXI
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] \
    [get_bd_intf_pins microgpt_top_fpga_0/s_axi]

# Clocks: PS pl_clk0 -> all AXI endpoints
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins smartconnect_0/aclk] \
    [get_bd_pins microgpt_top_fpga_0/aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm1_fpd_aclk]

# Resets: PS pl_resetn0 -> all
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins smartconnect_0/aresetn] \
    [get_bd_pins microgpt_top_fpga_0/aresetn]

puts "--- AXI connection: PS M_AXI_HPM0_FPD -> SmartConnect -> microGPT ---"

# --- 3d. Connect IRQ to PS ---
connect_bd_net [get_bd_pins microgpt_top_fpga_0/irq] \
    [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

puts "--- IRQ connected to PS pl_ps_irq0 ---"

# --- 3e. Assign Address Map ---
# PS HPM0_FPD -> microGPT registers at 0xA0000000, 64KB range
assign_bd_address [get_bd_addr_segs {microgpt_top_fpga_0/s_axi/reg0}] \
    -offset 0xA0000000 -range 4K

puts "--- Address map: microGPT at 0xA0000000 (4KB) ---"

# --- 3f. Validate and Save ---
validate_bd_design
save_bd_design

puts "--- Block design validated and saved ---"

# ============================================================================
# 4. Create HDL Wrapper (auto-generated by Vivado)
# ============================================================================
make_wrapper -files [get_files design_1.bd] -top
add_files -norecurse ${PROJ_DIR}/microgpt_zcu106.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v

set_property top design_1_wrapper [current_fileset]

puts "--- HDL wrapper created, top: design_1_wrapper ---"

# ============================================================================
# 5. Add DRC Overrides (PS+PL flow has no external IO)
# ============================================================================
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

puts "--- DRC overrides applied ---"

# ============================================================================
# 6. Synthesis
# ============================================================================
puts "============================================================"
puts " Starting Synthesis..."
puts "============================================================"

launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "Synthesis status: ${synth_status}"

if {${synth_status} != "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"
    set run_dir [get_property DIRECTORY [get_runs synth_1]]
    if {[file exists ${run_dir}/runme.log]} {
        file copy -force ${run_dir}/runme.log ${OUT_DIR}/zcu106_synth_fail.log
        puts "Synthesis log: ${OUT_DIR}/zcu106_synth_fail.log"
    }
    close_project
    exit 1
}

puts "--- Synthesis complete ---"

open_run synth_1
report_utilization -file ${OUT_DIR}/zcu106_synth_util.rpt
report_timing -file ${OUT_DIR}/zcu106_synth_timing.rpt -max_paths 10
close_design

# ============================================================================
# 7. Implementation (Place & Route)
# ============================================================================
puts "============================================================"
puts " Starting Implementation..."
puts "============================================================"

launch_runs impl_1 -jobs 4
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "Implementation status: ${impl_status}"

if {${impl_status} != "route_design Complete!"} {
    puts "ERROR: Implementation failed!"
    set run_dir [get_property DIRECTORY [get_runs impl_1]]
    if {[file exists ${run_dir}/runme.log]} {
        file copy -force ${run_dir}/runme.log ${OUT_DIR}/zcu106_impl_fail.log
        puts "Implementation log: ${OUT_DIR}/zcu106_impl_fail.log"
    }
    close_project
    exit 1
}

puts "--- Implementation complete ---"

open_run impl_1
report_utilization -file ${OUT_DIR}/zcu106_impl_util.rpt
report_timing_summary -file ${OUT_DIR}/zcu106_impl_timing_summary.rpt
report_timing -file ${OUT_DIR}/zcu106_impl_timing.rpt -max_paths 20
report_power -file ${OUT_DIR}/zcu106_impl_power.rpt

# --- Gate: Utilization threshold check ---
puts "--- Checking utilization thresholds ---"
set util_rpt [report_utilization -return_string]
# Vivado format: "| CLB LUTs    | 15000 | 0 | 234240 | 6.40 |"
set lut_line [regexp -inline -line {^\|\s*CLB LUTs\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*(\d+)} $util_rpt]
if {[llength $lut_line] >= 3} {
    set lut_used [lindex $lut_line 1]
    set lut_total [lindex $lut_line 2]
    if {$lut_total > 0} {
        set lut_pct [expr {$lut_used * 100.0 / $lut_total}]
        puts [format "  CLB LUTs: %d / %d (%.1f%%)" $lut_used $lut_total $lut_pct]
        if {$lut_pct > 80} {
            puts "ERROR: CLB LUT utilization exceeds 80%!"
            close_design
            close_project
            exit 1
        }
    }
} else {
    puts "  WARNING: Could not parse LUT utilization from report"
}

# --- Gate: Timing (WNS) check ---
puts "--- Checking timing (WNS) ---"
# Query WNS from the run's STATS properties (populated after route_design)
set wns [get_property STATS.WNS [get_runs impl_1]]
puts "  WNS = ${wns} ns"
if {[string is double -strict ${wns}] && ${wns} < 0} {
    puts "ERROR: Timing not met! WNS = ${wns} ns (negative = violation)"
    close_design
    close_project
    exit 1
}
puts "--- Timing OK (WNS=${wns}ns) ---"

close_design

# ============================================================================
# 8. Bitstream Generation
# ============================================================================
puts "============================================================"
puts " Generating Bitstream..."
puts "============================================================"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set bit_status [get_property STATUS [get_runs impl_1]]
puts "Bitstream status: ${bit_status}"

if {${bit_status} != "write_bitstream Complete!"} {
    puts "ERROR: Bitstream generation failed!"
    set run_dir [get_property DIRECTORY [get_runs impl_1]]
    if {[file exists ${run_dir}/runme.log]} {
        file copy -force ${run_dir}/runme.log ${OUT_DIR}/zcu106_bit_fail.log
        puts "Bitstream log: ${OUT_DIR}/zcu106_bit_fail.log"
    }
    close_project
    exit 1
}

puts "--- Bitstream generated ---"

set BIT_SRC ${PROJ_DIR}/microgpt_zcu106.runs/impl_1/design_1_wrapper.bit
set BIT_DST ${OUT_DIR}/microgpt_zcu106.bit

if {[file exists ${BIT_SRC}]} {
    file copy -force ${BIT_SRC} ${BIT_DST}
    puts "Bitstream: ${BIT_DST} ([file size ${BIT_DST}] bytes)"
} else {
    set alt_bit [glob -nocomplain ${PROJ_DIR}/microgpt_zcu106.runs/impl_1/*.bit]
    if {[llength ${alt_bit}] > 0} {
        file copy -force [lindex ${alt_bit} 0] ${BIT_DST}
        puts "Bitstream (alt): ${BIT_DST} ([file size ${BIT_DST}] bytes)"
    } else {
        puts "WARNING: Bitstream file not found"
    }
}

# ============================================================================
# 9. Export XSA (Hardware Platform)
# ============================================================================
puts "============================================================"
puts " Exporting XSA..."
puts "============================================================"

set XSA_FILE ${PROJ_DIR}/microgpt_zcu106.xsa
write_hw_platform -fixed -include_bit -file ${XSA_FILE}

if {[file exists ${XSA_FILE}]} {
    puts "XSA exported: ${XSA_FILE} ([file size ${XSA_FILE}] bytes)"
} else {
    puts "WARNING: XSA file not found after export"
}

# ============================================================================
# 10. Summary
# ============================================================================
puts ""
puts "============================================================"
puts " BUILD COMPLETE -- PS+PL Block Design (ZCU106)"
puts "============================================================"
puts " Top module:    design_1_wrapper (Block Design)"
puts " Part:          ${PART}"
puts " PS Config:     ZCU106 Board Preset, pl_clk0=100MHz"
puts " PL Design:     microgpt_top_fpga (microGPT inference engine)"
puts " AXI Path:      PS HPM0_FPD -> SmartConnect -> microGPT S_AXI"
puts " Address Map:   0xA000_0000 - 0xA000_0FFF (4KB, microGPT registers)"
puts " IRQ:           microgpt_top_fpga.irq -> PS pl_ps_irq0[0]"
puts ""
puts " Outputs:"
puts "   Bitstream:   ${BIT_DST}"
puts "   XSA:         ${XSA_FILE}"
puts "   Reports:     ${OUT_DIR}/zcu106_*.rpt"
puts ""
puts " Next Steps:"
puts "   1. Program FPGA: source syn/vivado_zcu106/download_microgpt.tcl"
puts "   2. Vitis: import XSA to create baremetal application"
puts "   3. Run microgpt_baremetal_main.c on Cortex-A53"
puts "   4. UART output (115200 8N1): inference results"
puts "============================================================"

close_project
