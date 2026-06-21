# TALOS-V2 移植到 Xilinx ZCU106 FPGA 完整文档

> 日期：2026-06-21
> 状态：**已完成**
> 目标 FPGA：Xilinx XCZU7EV-2FFVC1156E (ZCU106)

---

## 1. 需求概述

### 1.1 目标

将 TALOS-V2 microGPT 推理引擎从 Intel DE1-SoC (Cyclone V) 移植到 Xilinx ZCU106 (Zynq UltraScale+ XCZU7EV) 开发板，实现：

- PS (Cortex-A53) 通过 AXI4-Lite 寄存器控制 PL 侧推理引擎
- 裸机程序作为输入（配置参数、触发推理）
- UART 串口输出推理结果（token 序列、logits、性能数据）

### 1.2 原平台概况

| 项目 | 原始 (DE1-SoC) |
|------|----------------|
| FPGA | Intel Cyclone V |
| 时钟 | 56.25 MHz (sys_pll_56_25, altpll) |
| 主机接口 | JTAG-to-Avalon 桥 (Intel Qsys IP) |
| 时钟域 | 2 个 (50 MHz JTAG + 56.25 MHz core) |
| 域间通信 | Toggle 同步器 (CDC) |
| 板级 I/O | HEX0-5, LEDR0-9, SW0-1 |
| 构建工具 | Intel Quartus Prime 18.1 |
| 推理控制 | System Console TCL 脚本 |

### 1.3 目标平台

| 项目 | 目标 (ZCU106) |
|------|---------------|
| FPGA | Xilinx Zynq UltraScale+ XCZU7EV |
| 时钟 | 100 MHz (PS PL_CLK0) |
| 主机接口 | AXI4-Lite (PS M_AXI_HPM0_FPD → SmartConnect) |
| 时钟域 | 1 个 (100 MHz，无需 CDC) |
| 板级 I/O | UART0 (MIO，串口输出) |
| 构建工具 | Xilinx Vivado 2025.2 + Vitis |
| 推理控制 | Cortex-A53 裸机 C 程序 |

---

## 2. 架构设计

### 2.1 系统架构

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

### 2.2 数据流

```
PS 裸机程序
  │
  ├─ 写 REG_CONFIG    → 设置 temperature, max_gen
  ├─ 写 REG_SEED      → 设置 RNG 种子
  ├─ 写 REG_CONTROL   → 触发 start
  │
  ▼
PL microgpt_top_fpga
  │
  ├─ AXI4-Lite Slave 解析写事务 → 更新 host 寄存器
  ├─ FSM 捕获 start 请求 → 启动 microgpt_exact_core
  ├─ Core 执行推理 (embed → RMSNorm → Attn → MLP → lm_head → sample)
  ├─ FSM 循环生成 token 直到 BOS 或 max_gen
  │
  ▼
PS 裸机程序 (轮询 STATUS 寄存器)
  │
  ├─ 读 REG_STATUS    → 检查 done 位
  ├─ 读 REG_OUTPUT    → 读取输出 token (0-15)
  ├─ 读 REG_LOGITS    → 读取 27 个 raw logits
  ├─ 读 REG_PERF      → 读取性能计数器
  │
  ▼
UART 串口输出
```

---

## 3. 文件清单

### 3.1 新增文件

| 文件 | 行数 | 用途 |
|------|------|------|
| `syn/vivado_zcu106/microgpt_top_fpga.v` | 517 | AXI4-Lite FPGA 封装，替换 JTAG/Avalon 接口 |
| `scripts/vivado_zcu106.tcl` | 338 | 一键 Vivado 构建脚本 (综合→实现→比特流→XSA) |
| `syn/vivado_zcu106/microgpt_baremetal_main.c` | 282 | Cortex-A53 裸机测试程序 |
| `syn/vivado_zcu106/download_microgpt.tcl` | 102 | xsdb FPGA 烧录 + 应用下载脚本 |
| `syn/vivado_zcu106/README.md` | 199 | 使用说明文档 |
| `docs/ZCU106_Port_Guide.md` | — | 本文档 |

### 3.2 未修改的文件（平台无关，直接复用）

| 文件 | 说明 |
|------|------|
| `rtl/src/microgpt_exact_core.sv` | 推理引擎核心 (41 状态 FSM) |
| `rtl/src/systolic_matvec16_tile.sv` | 16-lane 脉动阵列 MAC |
| `rtl/src/rms_scale_engine.sv` | RMSNorm 归一化引擎 |
| `rtl/src/sat_div16_engine.sv` | 注意力输出饱和除法器 |
| `rtl/src/microgpt_categorical_sampler.sv` | 分类采样器 (xorshift32 RNG) |
| `rtl/src/include/microgpt_exact_core_params.svh` | 模型参数 + FSM 状态编码 |
| `rtl/src/include/microgpt_exact_core_math.svh` | 定点数学函数 |
| `rtl/src/include/microgpt_exact_core_rom_init.svh` | ROM 初始化 ($readmemh) |
| `rtl/generated/*.hex` (9 个) | Q4.12 模型权重 ROM 文件 |

### 3.3 不再使用的文件

| 文件 | 说明 |
|------|------|
| `rtl/src/de1_soc_microgpt_rtl.sv` | 原 DE1-SoC 顶层 (含 JTAG 桥 + 板级 I/O) |
| `rtl/src/sys_pll_56_25.v` | Intel altpll (Cyclone V 专用) |
| `rtl/ip/jtag_microgpt_bridge/` | Intel Qsys JTAG-to-Avalon 桥 IP |
| `*.bat` (根目录) | Intel Quartus 批处理脚本 |

---

## 4. 关键改造详解

### 4.1 AXI4-Lite Slave 封装 (`microgpt_top_fpga.v`)

**改造思路**：将原 `de1_soc_microgpt_rtl.sv` 中 JTAG 桥 + CDC 同步器 + 板级 I/O 逻辑替换为标准 AXI4-Lite Slave 接口，保留寄存器映射和 FSM 推理控制逻辑不变。

**关键设计决策**：

| 决策 | 原设计 | 新设计 | 原因 |
|------|--------|--------|------|
| 时钟域 | 2 个 (50M + 56.25M) | 1 个 (100M) | 消除 CDC，简化设计 |
| PLL | sys_pll_56_25 (altpll) | 无 (直接用 PS PL_CLK0) | UltraScale+ 100M 时序轻松收敛 |
| 主机通信 | JTAG Avalon-MM | AXI4-Lite | Zynq PS 标准接口 |
| 状态输出 | HEX + LED | 寄存器读取 | PS 通过 UART 输出 |
| 中断 | 无 | `irq = done_latched_reg` | PS 可选中断驱动 |

**AXI4-Lite 写通道实现**：

```
AW 通道: s_axi_awvalid & ~wr_addr_valid → 锁存地址, wr_addr_valid=1
W  通道: s_axi_wvalid  & ~wr_data_valid → 锁存数据, wr_data_valid=1
合并:    wr_addr_valid & wr_data_valid  → write_en 脉冲, bvalid=1
B 通道:  bvalid & s_axi_bready          → bvalid=0, 完成
```

**AXI4-Lite 读通道实现**：

```
AR 通道: s_axi_arvalid & ~rd_pending & ~rvalid → 锁存地址, rd_pending=1
R 通道:  rd_pending & ~rvalid                  → rvalid=1, rdata=read_data_comb
完成:    rvalid & s_axi_rready                  → rvalid=0
```

### 4.2 寄存器映射

基地址：`0xA000_0000` (PS 地址空间，Vivado Block Design 分配)

| 字节偏移 | 字地址 | R/W | 名称 | 位域 |
|----------|--------|-----|------|------|
| 0x000 | 0x000 | R | MAGIC | `0x4D475254` ("MGRT") |
| 0x004 | 0x001 | R | VERSION | `0x00020001` |
| 0x008 | 0x002 | W | CONTROL | bit0=start, bit1=clear |
| 0x00C | 0x003 | R | STATUS | `{pos[7:0], out_len[7:0], 8'd0, 2'd0, direct, 0, error, done, busy, ready}` |
| 0x010 | 0x004 | W | CONFIG | `{temperature[15:0], max_gen[7:0], 8'd0}` |
| 0x014 | 0x005 | R/W | SEED | xorshift32 种子 |
| 0x018 | 0x006 | R | DEBUG | `{top_logit[15:0], argmax_token[7:0], last_token[7:0]}` |
| 0x01C | 0x007 | R | BOS | `{16'd0, 8'd0, BOS_TOKEN}` |
| 0x020 | 0x008 | R/W | STEP_CFG | `{8'd0, step_token, step_pos, step_clear, direct_mode}` |
| 0x024 | 0x009 | W | STEP_TRIG | bit0=step toggle |
| 0x028 | 0x00A | W | DISPLAY | bit0=clear, bit1=append char[15:8] |
| 0x060–0x09C | 0x018–0x027 | R | OUTPUT | 16 个输出 token 字节 |
| 0x0D8 | 0x036 | R | PERF_CYC | 推理周期计数器 |
| 0x0DC | 0x037 | R | TOK_SEC | 每秒 token 数 |
| 0x100–0x168 | 0x040–0x05A | R | LOGITS | 27 × 16-bit 原始 logits |

### 4.3 Vivado Block Design

```
PS M_AXI_HPM0_FPD (32-bit addr, 32-bit data)
    │
    ▼
SmartConnect S00_AXI (1 SI, 1 MI)
    │
    ▼
SmartConnect M00_AXI
    │
    ▼
microgpt_top_fpga/s_axi (地址截断: 32-bit → 12-bit)
    │
    ▼
microgpt_exact_core (推理引擎)
```

时钟/复位连接：
- `PS pl_clk0` → SmartConnect/aclk, microgpt_top_fpga/aclk, PS AXI 端口时钟
- `PS pl_resetn0` → SmartConnect/aresetn, microgpt_top_fpga/aresetn

地址映射：
- 基地址：`0xA000_0000`
- 范围：4 KB (`0xA000_0000` – `0xA000_0FFF`)
- 内部解码：`s_axi_awaddr[11:2]`（12-bit 字节地址，10-bit 字地址）
- 注：SmartConnect 最小粒度对齐可能显示更大范围，但实际有效 4KB

中断：
- `microgpt_top_fpga/irq` → `PS pl_ps_irq0[0]`

### 4.4 裸机程序 (`microgpt_baremetal_main.c`)

运行在 Cortex-A53 (standalone)，通过 `Xil_In32`/`Xil_Out32` 访问 PL 寄存器。

**执行流程**：

```
1. 读 MAGIC/VERSION → 验证连接
2. 写 CONTROL bit1  → 清除状态
3. 写 CONFIG        → 设置 temperature=0x0080, max_gen=15
4. 写 SEED          → 设置 RNG 种子
5. 写 CONTROL bit0  → 触发推理
6. 轮询 STATUS      → 等待 done 位 (100μs 间隔, 最长 10s)
7. 读 OUTPUT        → 解码 token 为 a-z 文本
8. 读 LOGITS        → 打印 27 个 Q4.12 原始值
9. 读 PERF_CYC      → 打印推理周期数
10. UART printf      → 串口输出全部结果
```

**Token 解码**：token 0-25 → 'a'-'z'，token 26 → BOS (终止符)

### 4.5 `$readmemh` 路径修复

**问题**：`microgpt_exact_core_rom_init.svh` 中 `$readmemh("generated/wte_q12.hex", ...)` 是相对于调用文件目录的。Vivado 综合时，`.svh` 被 include 到 `rtl/src/`，但 hex 文件在 `rtl/generated/`，路径解析为 `rtl/src/generated/wte_q12.hex`（不存在）。

**解决**：`vivado_zcu106.tcl` 在添加 RTL 源文件前，自动将 `rtl/generated/*.hex` 复制到 `rtl/src/generated/`（Windows）或创建符号链接（Linux）。

---

## 5. Bug 修复记录

移植过程中发现并修复了以下问题：

### 5.1 AXI4-Lite 写通道 Bug（严重）

**现象**：`write_en` 在 AW+W 同时到达时永远不触发，所有写操作丢失。

**根因**：原条件 `axi_awready && s_axi_awvalid && ~axi_wready && s_axi_wvalid` 使用当前周期的 `axi_awready`/`axi_wready`。当主同时发 AW+W 时，两个 ready 同时拉高，下一周期 `~axi_wready=0`，条件不满足。

**时序分析**：
```
周期N:   awready=0, wready=0
周期N+1: awready=1, wready=1 (两个都锁存)
         write_en <= (0 && 1 && ~0 && 1) = 0  ← 旧 awready=0
周期N+2: awready=0, wready=0
         write_en <= (1 && 1 && ~1 && 1) = 0  ← ~wready=0
结果: write_en 永远为 0
```

**修复**：改用 `wr_addr_valid`/`wr_data_valid` 标志，独立锁存 AW 和 W 通道，两者都有效时产生单周期 `write_en` 脉冲。

### 5.2 AXI4-Lite 读通道 Bug（严重）

**现象**：`rvalid` 在 `arvalid` 提前释放时永远不触发。

**根因**：条件 `axi_arready && s_axi_arvalid && ~axi_rvalid` 要求 `arvalid` 在握手后仍保持高。但 AXI4-Lite 规范允许主在握手后立即释放 `arvalid`。

**修复**：改用 `rd_pending` 标志，地址握手后不再依赖 `arvalid`。

### 5.3 变量重命名遗漏（编译错误）

**现象**：AXI 信号重命名 `write_data` → `wr_data_latched` 后，写处理器中仍有 10 处 `write_data` 引用。

**修复**：全部替换为 `wr_data_latched`。

### 5.4 `$readmemh` 路径解析失败（功能问题）

**现象**：Vivado 综合时找不到 hex 文件。

**修复**：TCL 脚本预处理阶段将 hex 文件复制到 `rtl/src/generated/`。

---

## 6. 构建与运行

### 6.1 硬件构建 (Vivado)

```bash
vivado -mode batch -nolog -nojournal -source scripts/vivado_zcu106.tcl
```

产出：
- `build/microgpt_zcu106.bit` — 比特流
- `build/vivado_zcu106/microgpt_zcu106.xsa` — 硬件平台
- `build/zcu106_*.rpt` — 综合/实现报告

构建包含自动门禁检查：
- **Utilization 门禁**：CLB LUT > 80% 时构建失败
- **Timing 门禁**：WNS < 0（时序违规）时构建失败

### 6.1.1 WSL2 环境注意事项

PS+PL 构建涉及 Zynq PS IP 综合，内存消耗比纯 PL 构建更大。

**建议**：如在 WSL2 下构建，修改 `%UserProfile%\.wslconfig`：

```ini
[wsl2]
memory=20GB
swap=16GB
```

构建前确认可用内存 > 12GB。Vivado 综合 Zynq PS IP 时峰值内存约 8-10GB。

### 6.2 软件构建 (Vitis)

1. 导入 XSA：`build/vivado_zcu106/microgpt_zcu106.xsa`
2. Platform：standalone + psu_cortexa53_0
3. Application：Empty Application (C)
4. 添加 `syn/vivado_zcu106/microgpt_baremetal_main.c`
5. 编译产出 `microgpt_baremetal_app.elf`

### 6.3 烧录与运行

```bash
# 方式一：xsdb 脚本
xsdb syn/vivado_zcu106/download_microgpt.tcl

# 方式二：手动
xsdb
  connect
  targets -set -filter {name =~ "PSU"}
  fpga -file build/microgpt_zcu106.bit
  targets -set -filter {name =~ "Cortex-A53 #0"}
  dow build/fsbl.elf; con; after 2000; stop
  dow build/microgpt_baremetal_app.elf; con
```

### 6.4 串口输出

打开 UART 终端 (115200 8N1)，预期输出：

```
============================================
 microGPT ZCU106 Bare-Metal Test
 PL Base: 0xA0000000
============================================

[Test 1] Register connectivity
  Magic:   0x4D475254 ('MGRT' PASS)
  Version: 0x00020001
  BOS:     0x0000001A (token=26)

[Test 2] Clear and verify ready
  Status after clear: 0x00000001 -- PASS (ready)

[Test 3] Inference run
=== microGPT Inference on ZCU106 ===
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
Raw logits:  [-234, 567, ...]
=== Done ===
```

---

## 7. 资源估算

| 资源 | 估算使用 | ZCU106 可用 | 利用率 |
|------|----------|-------------|--------|
| CLB LUTs | ~15,000 | 234,240 | ~6% |
| CLB Registers | ~25,000 | 468,480 | ~5% |
| DSP48E2 | ~38 | 1,728 | ~2% |
| BRAM36 | ~2 | 312 | <1% |

资源利用率极低，有充足余量扩展（如 2-tile、更大模型）。

---

## 8. 变更记录

| 日期 | 版本 | 变更内容 |
|------|------|----------|
| 2026-06-21 | 1.0 | 初始移植版本，完成 PS+PL 联合验证 |
| 2026-06-21 | 1.1 | 修复 AXI4-Lite 写/读通道时序 Bug，修复 `$readmemh` 路径 |
