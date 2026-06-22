# ============================================================================
# download_microgpt.tcl -- xsdb script to program ZCU106 and run microGPT
# ============================================================================
# Programs the FPGA with the bitstream and optionally downloads/runs the
# bare-metal application.
#
# Usage (from xsdb or Vivado Tcl console):
#   source syn/vivado_zcu106/download_microgpt.tcl
#
# Or from command line:
#   xsdb syn/vivado_zcu106/download_microgpt.tcl
#
# Prerequisites:
#   - ZCU106 powered on and connected via JTAG
#   - Bitstream: build/microgpt_zcu106.bit
#   - (Optional) Application ELF: build/microgpt_baremetal_app.elf
#
# Revision: 2026-06-21
# ============================================================================

# Configuration
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set BUILD_DIR [file normalize "${SCRIPT_DIR}/../../build"]
set BITSTREAM [file normalize "${BUILD_DIR}/microgpt_zcu106.bit"]
set APP_ELF   [file normalize "${BUILD_DIR}/microgpt_baremetal_app.elf"]
set FSBL_ELF  [file normalize "${BUILD_DIR}/fsbl.elf"]

puts "============================================"
puts " microGPT ZCU106 Download Script"
puts "============================================"

# Step 1: Connect to target
puts "\n--- Connecting to target ---"
connect

# Step 2: Select the Zynq UltraScale+ device
puts "--- Selecting target ---"
targets -set -filter {name =~ "PSU"}

# Step 3: Program FPGA
puts "\n--- Programming FPGA ---"
if {![file exists ${BITSTREAM}]} {
    puts "ERROR: Bitstream not found: ${BITSTREAM}"
    puts "       Run: vivado -mode batch -source scripts/vivado_zcu106.tcl"
    disconnect
    exit 1
}
fpga -file ${BITSTREAM}
after 500
puts "FPGA programmed: ${BITSTREAM}"

# Step 4: Initialize PS (load FSBL for DDR init)
puts "\n--- Initializing PS ---"
if {[file exists ${FSBL_ELF}]} {
    # Use FSBL for proper DDR/memory initialization
    targets -set -filter {name =~ "Cortex-A53 #0"}
    dow ${FSBL_ELF}
    con
    after 2000
    stop
    puts "PS initialized via FSBL"
} else {
    # No FSBL: use psu_init.tcl from XSA (if available)
    puts "WARNING: FSBL not found at ${FSBL_ELF}"
    puts "         Attempting direct PS init..."
    targets -set -filter {name =~ "Cortex-A53 #0"}
    # Try to source psu_init if available
    set psu_init [file normalize "${BUILD_DIR}/vivado_zcu106/microgpt_zcu106.gen/sources_1/bd/design_1/hw_handoff/psu_init.tcl"]
    if {[file exists ${psu_init}]} {
        source ${psu_init}
        psu_init
        puts "PS initialized via psu_init.tcl"
    } else {
        puts "WARNING: No PS initialization source found."
        puts "         DDR may not be initialized. Application may fail."
    }
}

# Step 4b: Verify bitstream loaded correctly (read MAGIC register)
puts "\n--- Verifying bitstream ---"
after 200
set magic_val ""
catch {memmap -addr 0xA0000000 -size 0x00001000 -flags 3}
catch {set magic_val [mrd -value 0xA0000000]}
if {${magic_val} == "0x4d475254" || ${magic_val} == "0x4D475254"} {
    puts "  MAGIC = ${magic_val} -- PASS (bitstream verified)"
} elseif {${magic_val} == ""} {
    puts "  WARNING: Could not read MAGIC register (PS may need init)"
    puts "           Continuing anyway..."
} else {
    puts "  MAGIC = ${magic_val} -- UNEXPECTED (expected 0x4D475254)"
    puts "  WARNING: Bitstream may not have loaded correctly"
    puts "           Check JTAG connection and power"
}

# Step 5: Download and run application (if available)
if {[file exists ${APP_ELF}]} {
    puts "\n--- Downloading application ---"
    targets -set -filter {name =~ "Cortex-A53 #0"}
    dow ${APP_ELF}
    puts "Application loaded: ${APP_ELF}"

    puts "\n--- Starting application ---"
    puts "Open UART terminal (115200 8N1) to see output."
    puts "Press Ctrl+C in xsdb to stop.\n"
    con
} else {
    puts "\n--- No application ELF found ---"
    puts "Application ELF: ${APP_ELF} (not found)"
    puts "Build with Vitis, then re-run this script."
    puts "\nFPGA is programmed. You can manually:"
    puts "  1. Create Vitis application from XSA"
    puts "  2. Build: microgpt_baremetal_app.elf"
    puts "  3. Download: dow ${APP_ELF}"
    puts "  4. Run: con"
}

puts "\n============================================"
puts " Download complete"
puts "============================================"
