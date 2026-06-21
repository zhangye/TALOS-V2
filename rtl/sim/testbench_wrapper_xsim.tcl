# ============================================================================
# testbench_wrapper_xsim.tcl — Vivado XSIM: Wrapper Testbench
# ============================================================================
# Runs tb_microgpt_top_fpga in Vivado's built-in simulator (XSIM).
# No ModelSim license required.
#
# Usage (from repo root):
#   vivado -mode batch -source rtl/sim/testbench_wrapper_xsim.tcl
#
# Tests: AXI4-Lite protocol, register map, FSM, max_gen validation,
#        deterministic output, SLVERR, clear+re-run.
# ============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set RTL_DIR [file normalize "${SCRIPT_DIR}/../src"]
set SIM_DIR [file normalize "${SCRIPT_DIR}"]
set OUT_DIR [file normalize "${SCRIPT_DIR}/../../build/xsim_wrapper"]

file mkdir ${OUT_DIR}

puts "============================================================"
puts " XSIM Wrapper Testbench"
puts " RTL:  ${RTL_DIR}"
puts " SIM:  ${SIM_DIR}"
puts " OUT:  ${OUT_DIR}"
puts "============================================================"

# Create project (use temp dir for XSIM compatibility)
set PROJ_DIR [file normalize "${OUT_DIR}/xsim_proj"]
file mkdir ${PROJ_DIR}
create_project tb_wrapper_xsim ${PROJ_DIR} -part xczu7ev-ffvc1156-2-e -force

# Add RTL sources
set_property include_dirs ${RTL_DIR}/include [current_fileset]
set_property include_dirs ${RTL_DIR}/include [get_filesets sim_1]

read_verilog -sv ${RTL_DIR}/include/microgpt_exact_core_params.svh
read_verilog -sv ${RTL_DIR}/include/microgpt_exact_core_math.svh
read_verilog -sv ${RTL_DIR}/include/microgpt_exact_core_rom_init.svh
read_verilog -sv ${RTL_DIR}/microgpt_exact_core.sv
read_verilog -sv ${RTL_DIR}/systolic_matvec16_tile.sv
read_verilog -sv ${RTL_DIR}/rms_scale_engine.sv
read_verilog -sv ${RTL_DIR}/sat_div16_engine.sv
read_verilog -sv ${RTL_DIR}/microgpt_categorical_sampler.sv

# Add wrapper (the module under test)
set WRAPPER_FILE [file normalize "${SCRIPT_DIR}/../../syn/vivado_zcu106/microgpt_top_fpga.v"]
read_verilog ${WRAPPER_FILE}

# Add testbench
read_verilog -sv ${SIM_DIR}/tb_microgpt_top_fpga.sv

# Copy hex files for $readmemh
set HEX_SRC [file normalize "${SCRIPT_DIR}/../generated"]
set HEX_DST [file normalize "${RTL_DIR}/generated"]
if {[file exists ${HEX_SRC}] && ![file exists ${HEX_DST}]} {
    file mkdir ${HEX_DST}
    foreach f [glob -nocomplain ${HEX_SRC}/*.hex] {
        file copy -force $f ${HEX_DST}/
    }
}

# Set top for simulation
set_property top tb_microgpt_top_fpga [get_filesets sim_1]

# Copy hex files to XSIM working directory ($readmemh resolves from cwd)
set XSIM_DIR "${PROJ_DIR}/tb_wrapper_xsim.sim/sim_1/behav/xsim"
if {[file exists ${HEX_SRC}]} {
    file mkdir "${XSIM_DIR}/generated"
    foreach f [glob -nocomplain ${HEX_SRC}/*.hex] {
        file copy -force $f "${XSIM_DIR}/generated/"
    }
    puts "--- Hex files copied to XSIM dir ---"
}

# XSIM resolves $readmemh relative to the .svh file directory (rtl/src/include/).
# Copy hex files there so "generated/wte_q12.hex" resolves correctly.
set HEX_INCLUDE_DST "${RTL_DIR}/include/generated"
if {[file exists ${HEX_SRC}]} {
    file mkdir ${HEX_INCLUDE_DST}
    foreach f [glob -nocomplain ${HEX_SRC}/*.hex] {
        file copy -force $f ${HEX_INCLUDE_DST}/
    }
    puts "--- Hex files copied to ${HEX_INCLUDE_DST} ---"
}

# Launch simulation (compile + elaborate + start)
puts "\n--- Launching XSIM simulation ---"
launch_simulation -mode behavioral

# Run all tests
run all

puts "\n--- Simulation complete ---"

# Check for errors in log
set sim_log "${OUT_DIR}/xsim.log"

close_project
