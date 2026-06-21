# TALOS-V2 on Xilinx ZCU106

Port of the microGPT inference engine from Intel DE1-SoC (Cyclone V) to Xilinx ZCU106 (Zynq UltraScale+ XCZU7EV).

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                Zynq UltraScale+ XCZU7EV (ZCU106)            │
├──────────────────────┬──────────────────────────────────────┤
│      PS (Cortex-A53) │           PL (microGPT RTL)          │
│                      │                                       │
│  ┌────────────────┐  │  ┌─────────────────────────────────┐ │
│  │  UART0 (MIO)   │  │  │  microgpt_top_fpga              │ │
│  │  → 串口输出    │  │  │  ┌───────────────────────────┐  │ │
│  ├────────────────┤  │  │  │  AXI4-Lite Slave         │  │ │
│  │  M_AXI_HPM0_FPD│──┼──│──│  (register map)           │  │ │
│  │                │  │  │  ├───────────────────────────┤  │ │
│  ├────────────────┤  │  │  │  microgpt_exact_core      │  │ │
│  │  DDR4 控制器   │  │  │  │  (inference engine)       │  │ │
│  └────────────────┘  │  │  └───────────────────────────┘  │ │
│                      │  └─────────────────────────────────┘ │
│                      │  PL_CLK0 = 100 MHz (来自 PS PLL)      │
└──────────────────────┴──────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `scripts/vivado_zcu106.tcl` | One-click Vivado build (synthesis → bitstream → XSA) |
| `syn/vivado_zcu106/microgpt_top_fpga.v` | AXI4-Lite FPGA wrapper for microGPT core |
| `syn/vivado_zcu106/microgpt_baremetal_main.c` | Bare-metal test application (Cortex-A53) |
| `syn/vivado_zcu106/download_microgpt.tcl` | xsdb FPGA programming + app download script |

## Quick Start

### Prerequisites

- Xilinx Vivado 2025.2 (or compatible)
- Xilinx Vitis 2025.2 (for bare-metal app)
- ZCU106 development board
- UART terminal (115200 8N1)

### Step 1: Build Hardware (Vivado)

```bash
vivado -mode batch -nolog -nojournal -source scripts/vivado_zcu106.tcl
```

This creates:
- `build/microgpt_zcu106.bit` — bitstream
- `build/vivado_zcu106/microgpt_zcu106.xsa` — hardware platform
- `build/zcu106_*.rpt` — synthesis/implementation reports

### Step 2: Build Software (Vitis)

1. Open Vitis, create workspace
2. **File → New → Platform Project** → import `build/vivado_zcu106/microgpt_zcu106.xsa`
   - OS: standalone
   - Processor: psu_cortexa53_0
3. **File → New → Application Project** → Empty Application (C)
4. Replace `src/` with `syn/vivado_zcu106/microgpt_baremetal_main.c`
5. Build → produces `microgpt_baremetal_app.elf`

### Step 3: Program & Run

#### Option A: Using xsdb script

```bash
# Copy ELF to build/ first
xsdb syn/vivado_zcu106/download_microgpt.tcl
```

#### Option B: Manual xsdb commands

```bash
xsdb
connect
targets -set -filter {name =~ "PSU"}
fpga -file build/microgpt_zcu106.bit
targets -set -filter {name =~ "Cortex-A53 #0"}
dow build/fsbl.elf
con
# wait 2s, then stop
dow build/microgpt_baremetal_app.elf
con
```

#### Option C: Using Vivado Hardware Manager

1. Open Vivado → Hardware Manager → Connect
2. Program FPGA with `build/microgpt_zcu106.bit`
3. Use xsdb or Vitis debugger to download ELF

### Step 4: View Output

Open UART terminal (PuTTY/minicom) at **115200 8N1** on ZCU106 UART0:

```
============================================
 microGPT ZCU106 Bare-Metal Test
 PL Base: 0xA0000000
============================================

[Test 1] Register connectivity
  Magic:   0x4D475254 ('MGRT' PASS)
  Version: 0x00020001

[Test 3] Inference run
Seed:        1
Temperature: Q8.8 = 0x0080 (0.5000)
Max tokens:  15
Inference started...

--- Results ---
Output len:  5 tokens
Output text: "delpy"
Token IDs:   [10, 4, 11, 15, 24]
Perf cycles: 123456
Tokens/sec:  810
```

## Register Map

Base address: `0xA000_0000` (64KB region)

| Byte Offset | Word Addr | R/W | Name | Description |
|-------------|-----------|-----|------|-------------|
| 0x000 | 0x000 | R | MAGIC | Hardware ID: `0x4D475254` ("MGRT") |
| 0x004 | 0x001 | R | VERSION | `0x00020001` |
| 0x008 | 0x002 | W | CONTROL | bit0=start, bit1=clear |
| 0x00C | 0x003 | R | STATUS | `{pos, out_len, 8'b0, 2'b0, direct, toggle, error, done, busy, ready}` |
| 0x010 | 0x004 | W | CONFIG | `{temperature[15:0], max_gen[7:0], 8'b0}` |
| 0x014 | 0x005 | R/W | SEED | RNG seed (xorshift32) |
| 0x018 | 0x006 | R | DEBUG | `{top_logit[15:0], argmax_token[7:0], last_token[7:0]}` |
| 0x01C | 0x007 | R | BOS | `{16'b0, 8'b0, BOS_TOKEN}` |
| 0x020 | 0x008 | R/W | STEP_CFG | `{8'b0, step_token, step_pos, step_clear, direct_mode}` |
| 0x024 | 0x009 | W | STEP_TRIG | bit0=step toggle |
| 0x028 | 0x00A | W | DISPLAY | bit0=clear, bit1=append char[15:8] |
| 0x060–0x09C | 0x018–0x027 | R | OUTPUT | 16 generated token bytes |
| 0x0D8 | 0x036 | R | PERF_CYC | Performance cycle counter |
| 0x0DC | 0x037 | R | TOK_SEC | Tokens per second |
| 0x100–0x168 | 0x040–0x05A | R | LOGITS | 27 × 16-bit signed raw logits |

## Key Design Decisions

| Aspect | DE1-SoC (original) | ZCU106 (this port) |
|--------|-------------------|-------------------|
| FPGA | Cyclone V | Zynq UltraScale+ XCZU7EV |
| Clock | 56.25 MHz (altpll) | 100 MHz (PS PL_CLK0) |
| Host interface | JTAG-to-Avalon bridge | AXI4-Lite (PS M_AXI_HPM0_FPD) |
| Clock domains | 2 (50MHz + 56.25MHz) | 1 (100MHz) |
| CDC synchronizers | Toggle-domain crossing | None needed |
| Board I/O | HEX, LED, SW | UART0 via PS |
| Build tool | Quartus Prime | Vivado 2025.2 |

## RTL Compatibility

The 5 core SystemVerilog modules and 3 `.svh` include files are **unchanged**:

- `microgpt_exact_core.sv` — inference FSM
- `systolic_matvec16_tile.sv` — MAC array
- `rms_scale_engine.sv` — RMSNorm
- `sat_div16_engine.sv` — attention divider
- `microgpt_categorical_sampler.sv` — token sampler
- `microgpt_exact_core_params.svh` — parameters
- `microgpt_exact_core_math.svh` — math functions
- `microgpt_exact_core_rom_init.svh` — ROM initialization

Only the top-level wrapper changed (from `de1_soc_microgpt_rtl.sv` to `microgpt_top_fpga.v`).

## Troubleshooting

### Magic reads as 0x00000000
- Bitstream not programmed, or FPGA not configured
- Check Vivado Hardware Manager connection

### Magic reads as 0xFFFFFFFF
- AXI bus not connected (SmartConnect or address map issue)
- Regenerate XSA and rebuild

### Synthesis fails with "cannot find module"
- Ensure `$readmemh` hex files are accessible
- Check `rtl/generated/` contains all 9 `.hex` files

### Timing not met (WNS negative)
- The design runs at 100 MHz on UltraScale+, which should easily close timing
- If issues occur, reduce PL_CLK0 frequency in PS configuration

## Resource Estimates

Based on the original DE1-SoC implementation (16-lane config):
- LUTs: ~15K (UltraScale+ has 234K available → ~6%)
- Registers: ~25K (UltraScale+ has 468K available → ~5%)
- DSP48E2: ~38 (UltraScale+ has 1728 available → ~2%)
- BRAM: minimal (ROM weights are LUT-based)

Expected to fit comfortably with significant headroom.
