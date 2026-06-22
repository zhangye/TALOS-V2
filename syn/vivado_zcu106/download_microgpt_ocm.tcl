# download_microgpt_ocm.tcl -- ZCU106 OCM-only JTAG download with explicit PS init
#
# Usage from WSL2:
#   /opt/Xilinx/Vitis/Vitis/bin/xsdb /mnt/c/workspace/TALOS-V2/syn/vivado_zcu106/download_microgpt_ocm.tcl
#
# Flow:
#   1. Program PL bitstream
#   2. Add PL AXI range to XSDB memory map
#   3. Source Vivado-generated psu_init.tcl
#   4. Reset A53, download OCM ELF, run

set base_dir "/mnt/c/workspace/TALOS-V2"
set bit_file "$base_dir/build/microgpt_zcu106.bit"
set elf_file "$base_dir/build/microgpt_ocm_bringup.elf"
set psu_init_candidates [list \
    "$base_dir/build/vivado_zcu106/microgpt_zcu106.gen/sources_1/bd/design_1/ip/design_1_zynq_ultra_ps_e_0_0/psu_init.tcl" \
    "$base_dir/build/vivado_zcu106/microgpt_zcu106.gen/sources_1/bd/design_1/hw_handoff/psu_init.tcl" \
]

proc add_pl_memmap {} {
    if {[catch {memmap -addr 0xA0000000 -size 0x00001000 -flags 3} err]} {
        puts "WARNING: memmap numeric flags failed: $err"
        if {[catch {memmap -addr 0xA0000000 -size 0x00001000 -flags rw} err2]} {
            puts "WARNING: memmap rw flags failed: $err2"
        }
    }
}

set psu_init_tcl ""
foreach candidate $psu_init_candidates {
    if {[file exists $candidate]} {
        set psu_init_tcl $candidate
        break
    }
}

puts "=== TALOS microGPT ZCU106 OCM download with psu_init ==="
puts "Bitstream : $bit_file"
puts "ELF       : $elf_file"
puts "PS init   : $psu_init_tcl"

foreach {path desc} [list $bit_file "Bitstream" $elf_file "OCM ELF"] {
    if {![file exists $path]} {
        puts "ERROR: $desc not found: $path"
        exit 1
    }
}

if {$psu_init_tcl eq ""} {
    puts "ERROR: psu_init.tcl not found under build/vivado_zcu106. Re-run Vivado bitstream generation."
    exit 1
}

connect
targets

puts "\n>>> Programming PL..."
targets -set -filter {name =~ "PSU"}
fpga -file $bit_file
after 2000

add_pl_memmap

puts "\n>>> Running psu_init.tcl..."
source $psu_init_tcl

if {[catch {psu_init} err]} {
    puts "WARNING: psu_init returned: $err"
    puts "         Continuing because OCM-only app does not require DDR."
}

if {[catch {psu_post_config} err]} {
    puts "WARNING: psu_post_config returned: $err"
}

after 1000
add_pl_memmap

puts "\n>>> First AXI sanity read..."
if {[catch {set magic_val [mrd -value 0xA0000000]} err]} {
    puts "ERROR: Failed to read MAGIC register: $err"
    exit 1
}
puts [format "MAGIC = 0x%08X" $magic_val]
if {$magic_val != 0x4D475254} {
    puts "ERROR: Unexpected MAGIC value. Expected 0x4D475254."
    exit 1
}

puts "\n>>> Downloading OCM ELF to A53 #0..."
targets -set -filter {name =~ "Cortex-A53 #0"}

catch {mwr 0xffff0000 0x14000000}
rst -processor -clear-registers
after 1000

if {[catch {dow $elf_file} err]} {
    puts "ERROR: Failed to download ELF: $err"
    exit 1
}

puts "\n>>> Starting application..."
con

puts "\n=== Download command complete ==="
puts "Check UART0 serial at 115200 8N1 for RESULT: PASS."
