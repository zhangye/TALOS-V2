# ZCU106 移植文档 Review 报告 (v2 — 深度源码审查)

> 日期：2026-06-21
> Review 对象：`docs/ZCU106_Port_Guide.md` + 全部实际源码逐行对比
> 参考：`C:\workspace\TPU\src_tpu_dc\docs\ZCU106_PS_PL_Hardware_Platform_经验文档.md` + 原始 `de1_soc_microgpt_rtl.sv`
> 方法：新 wrapper vs 原始 DE1-SoC 顶层逐寄存器、逐状态对比

---

## 一、LUT 资源评估：✅ 不会超，余量充足

| 对比项 | 历史经验文档 (TPU) | 移植文档估算 | 实际风险 |
|--------|-------------------|-------------|---------|
| CLB LUTs | 18,903 / 230,400 (8.2%) | ~15,000 / 234,240 (~6%) | **安全** |
| CLB Registers | 65,167 / 460,800 (14.14%) | ~25,000 / 468,480 (~5%) | **安全** |
| DSP48E2 | 未记录 | ~38 / 1,728 (~2%) | **安全** |
| BRAM36 | 未记录 | ~2 / 312 (<1%) | **安全** |

**关键差异分析**：

- TPU 用了 18,903 LUTs，但 TPU 有 16-lane MAC + 更复杂的 DMA 逻辑。microGPT 同样有 16-lane systolic tile，但 DMA master 全部 tie-off，少了大量 DMA 路径逻辑，估算 15,000 LUTs 合理。
- **文档中 ZCU106 可用 LUT 数字不一致**：经验文档写 230,400，移植文档写 234,240。实际 XCZU7EV 的 CLB LUTs 是 **234,240**（Vivado 报告中的数字），经验文档的 230,400 可能是旧版 Vivado 报告或四舍五入。**不影响结论**。
- 9 个 ROM 数组（~62.4 Kbits）会映射到 BRAM，ZU7EV 有 312 个 BRAM36（或等效 624 个 BRAM18K），占 3-4 个 BRAM36，完全无压力。

**结论：资源利用率 <10%，即使扩展到 2-tile 也绰绰有余。**

---

## 二、移植是否符合需求：⚠️ 有 1 个功能 Bug + 若干文档不一致

### ✅ 已满足的需求

| 需求 | 状态 | 说明 |
|------|------|------|
| PS 通过 AXI4-Lite 控制 PL | ✅ | HPM0_FPD → SmartConnect → microgpt_top_fpga |
| 裸机程序配置参数+触发推理 | ✅ | C 代码完整实现 Test 1-4 |
| UART 串口输出推理结果 | ✅ | 通过 printf → UART0 输出 |
| 消除 CDC（从 2 时钟域→1） | ✅ | 单时钟域 100MHz，无 CDC |
| 消除外部 IO 引脚约束 | ✅ | 全在片内，无需 XDC LOC |
| 模型权重 ROM 正确加载 | ✅ | $readmemh 路径已修复 |
| 寄存器映射完整移植 | ✅ | 新 wrapper vs DE1-SoC 全部 15 个寄存器对比一致 |
| AXI4-Lite 协议合规 | ✅ | 写通道 AW/W 独立锁存、读通道 rd_pending 标志 |
| SLVERR 未映射地址 | ✅ | read_err / write_err 已实现（第一轮 review 判断有误，已纠正） |

### 🔴 严重 Bug：`max_gen_reg` 校验用了旧值

**位置**：`microgpt_top_fpga.v` 第 390-402 行（ST_READY）和第 460-472 行（ST_DONE）

```verilog
// 第 390 行：先赋值
max_gen_reg      <= host_max_gen_reg;  // ← 非阻塞赋值，要等下一个时钟沿才生效
temperature_reg  <= host_temperature_reg;
rng_reg          <= host_seed_reg;
// ...
// 第 395 行：再校验 —— 此时 max_gen_reg 还是旧值！
if (max_gen_reg == 8'd0 || max_gen_reg > 8'd15) begin
    error_reg        <= 1'b1;
    done_latched_reg <= 1'b1;
    state_reg        <= ST_DONE;
end
```

**问题**：Verilog 非阻塞赋值 `<=` 在同一 always 块中，赋值要到下一个时钟沿才更新寄存器。所以第 395 行的 `max_gen_reg` 校验的是**上一次的旧值**，而不是刚刚从 host 写入的新值。

**影响**：
- 第一次推理（reset 后 `max_gen_reg = 15`）：旧值 15 合法，不会触发 error → **碰巧正确**
- 如果第一次推理设置 `max_gen = 0`（非法）：旧值 15 合法，不会触发 error → **Bug 被掩盖**
- 如果先跑一次 `max_gen = 5`，再跑一次 `max_gen = 0`：旧值 5 合法，不会触发 error → **Bug 暴露：非法值被接受**

**修复**：

```verilog
// 应该校验 host_max_gen_reg（新值），而不是 max_gen_reg（旧值）
if (host_max_gen_reg == 8'd0 || host_max_gen_reg > 8'd15) begin
    error_reg        <= 1'b1;
    done_latched_reg <= 1'b1;
    state_reg        <= ST_DONE;
end else begin
    max_gen_reg      <= host_max_gen_reg;
    temperature_reg  <= host_temperature_reg;
    rng_reg          <= host_seed_reg;
    start_core_reg   <= 1'b1;
    state_reg        <= ST_WAIT_CORE;
end
```

**注意**：原 DE1-SoC 版本（`de1_soc_microgpt_rtl.sv` 第 361 行）也有同样的 Bug，但因为在 toggle CDC 同步器下 `max_gen_reg <= host_max_gen_reg` 赋值发生在更早的 CDC 检测阶段（第 283 行），时序上可能碰巧正确。新 wrapper 去掉了 CDC，赋值和校验在同一个 always 块的同一分支，Bug 更容易暴露。

### ⚠️ 文档不一致 1：地址空间 64KB vs 实际 4KB

**实际 TCL 脚本**（`vivado_zcu106.tcl` 第 161 行）：

```tcl
assign_bd_address ... -offset 0xA0000000 -range 4K
```

实际是 **4KB**，不是文档中多处写的 64KB。Port Guide 第 12 行、第 218 行、README 第 126 行均写 64KB，与代码不一致。

**建议**：统一文档为 4KB。

### ⚠️ 文档不一致 2：轮询间隔

Port Guide 第 4.4 节写"100μs 间隔，最长 10s"。实际 C 代码中：

- `run_inference()` 的主轮询用 `usleep(100)` = 100μs，100,000 次 = 10s ✅
- `wait_for_status()` 用 `usleep(1000)` = 1ms，5000 次 = 5s

文档应明确区分两处轮询的不同间隔。

### ⚠️ 文档不一致 3：C 代码中 `REG_DISPLAY` 定义未使用

`microgpt_baremetal_main.c` 第 42 行定义了 `#define REG_DISPLAY (0x00A * 4)`，但整个 C 代码中没有使用这个宏。DE1-SoC 原始设计中 DISPLAY 寄存器用于 HEX 显示滚动，在 PS+PL 方案中 HEX 显示已移除。硬件 wrapper 中写处理器（第 280 行 default 分支）会静默忽略这个地址的写入。

**建议**：删除 C 代码中的 `REG_DISPLAY` 定义，或在文档中注明"已废弃"。

---

## 三、UART 串口 Log 输出：✅ 会正确输出

### 输出链路验证

```
PS Cortex-A53 standalone
  → printf() / xil_printf()
    → BSP stdout → UART0 (MIO 引脚)
      → 115200 8N1 串口终端
```

**关键依赖**：
1. **Board Preset 自动配置 UART0**：ZCU106 的 Board Preset 会自动配置 UART0 到 MIO（经验文档 6.2 节已验证）。✅
2. **BSP stdout 映射到 UART0**：Xilinx standalone BSP 默认将 `stdout` 映射到 `psu_uart_0`，XSA 中已使能。✅
3. **printf 格式正确**：C 代码使用标准 `printf`，ZCU106 的 BSP 支持 `%x`、`%d`、`%s`、`%c`、`%u`。✅
4. **Token 解码**：`token_to_char()` 正确处理 0-25→'a'-'z'，26→BOS→`\0`。✅
5. **C 代码已加 PS 启动心跳**：`main()` 第 226 行有 `printf("[PS] Boot OK...")`，可立即确认 UART 工作。✅

### ✅ 无风险项

- `usleep()` 依赖 PS Global Timer，FSBL 运行 2 秒后已初始化时钟 → 无风险
- 所有 `%d` 输出的 logits 是 `s16` 类型，第 211 行有正确的 `(s16)` 强制转换 → 负数输出正确
- `\r\n` 换行符兼容 Windows PuTTY 和 Linux minicom → 无风险

---

## 四、Bitstream 前门禁检查：✅ 完备

> **第一轮 review 判断有误，以下为纠正后的结论。**

### ✅ TCL 脚本已有的门禁（逐行确认）

| 检查项 | 状态 | 代码位置 |
|--------|------|---------|
| RTL 语法检查 | ✅ | `read_verilog -sv` (TCL 第 61-67 行) |
| 综合状态检查 | ✅ | `synth_status != "synth_design Complete!"` → exit 1 (第 202 行) |
| DRC override (NSTD-1/UCIO-1) | ✅ | 第 184-185 行 |
| 实现状态检查 | ✅ | `impl_status != "route_design Complete!"` → exit 1 (第 233 行) |
| **LUT 利用率阈值** | ✅ | `report_utilization -return_string` → 正则解析 → >80% 则 exit 1 (第 252-269 行) |
| **WNS 时序门禁** | ✅ | `get_property STATS.WNS` → <0 则 exit 1 (第 271-281 行) |
| 比特流状态检查 | ✅ | `bit_status != "write_bitstream Complete!"` → exit 1 (第 298 行) |
| XSA 导出含 bitstream | ✅ | `write_hw_platform -fixed -include_bit` (第 335 行) |
| $readmemh 路径 | ✅ | hex 文件预复制到 rtl/src/generated/ (第 78-98 行) |

### ✅ Download 脚本已有的门禁

| 检查项 | 状态 | 代码位置 |
|--------|------|---------|
| Bitstream 文件存在性 | ✅ | `file exists ${BITSTREAM}` → exit 1 (第 42 行) |
| **Bitstream 回读验证** | ✅ | `mrd -value 0xA0000000` 读 MAGIC 寄存器 (第 83 行) |
| FSBL 三级降级 | ✅ | FSBL ELF → psu_init.tcl → 警告 (第 54-77 行) |
| Application ELF 存在性 | ✅ | `file exists ${APP_ELF}` → 提示 (第 96 行) |

### ⚠️ 唯一遗漏：hex 文件过期不刷新

TCL 脚本第 81 行 `if {![file exists ${HEX_DST}]}` 只在目标目录不存在时才复制。如果 `rtl/generated/` 中的 hex 文件被更新（换了模型权重），但 `rtl/src/generated/` 已存在，Vivado 会继续使用旧的 hex 文件。

**建议**：改为比较时间戳或强制覆盖：

```tcl
# 替换第 81 行的条件判断
file mkdir ${HEX_DST}
foreach f [glob -nocomplain ${HEX_SRC}/*.hex] {
    set dst_f ${HEX_DST}/[file tail $f]
    if {![file exists $dst_f] || [file mtime $f] > [file mtime $dst_f]} {
        file copy -force $f ${HEX_DST}/
    }
}
```

---

## 五、与原始 DE1-SoC 的逐寄存器对比

| 寄存器 | 偏移 | DE1-SoC | ZCU106 wrapper | 一致性 |
|--------|------|---------|----------------|--------|
| MAGIC | 0x000 | `0x4D475254` ✅ | `0x4D475254` ✅ | ✅ |
| VERSION | 0x001 | `0x00020001` ✅ | `0x00020001` ✅ | ✅ |
| CONTROL | 0x002 | toggle CDC → pulse | 直接 pulse（无 CDC） | ✅ 改进 |
| STATUS | 0x003 | `{pos, out_len, 0, 0, direct, toggle, error, done, busy, ready}` | `{pos, out_len, 0, 0, direct, 0, error, done, busy, ready}` | ✅ (toggle 位清零) |
| CONFIG | 0x004 | `{temp, max_gen, 0}` ✅ | `{temp, max_gen, 0}` ✅ | ✅ |
| SEED | 0x005 | R/W ✅ | R/W ✅ | ✅ |
| DEBUG | 0x006 | `{top_logit, argmax, last}` ✅ | `{top_logit, argmax, last}` ✅ | ✅ |
| BOS | 0x007 | `{0, 0, 26}` ✅ | `{0, 0, 26}` ✅ | ✅ |
| STEP_CFG | 0x008 | R/W ✅ | R/W ✅ | ✅ |
| STEP_TRIG | 0x009 | toggle CDC → pulse | 直接 pulse | ✅ 改进 |
| DISPLAY | 0x00A | HEX 滚动逻辑 | 写忽略（HEX 已移除） | ✅ 预期 |
| OUTPUT | 0x018-0x027 | 16 × byte ✅ | 16 × byte ✅ | ✅ |
| PERF_CYC | 0x036 | `perf_cycles_reg` ✅ | `perf_cycles_reg` ✅ | ✅ |
| TOK_SEC | 0x037 | `tokens_per_sec_reg` ✅ | `tokens_per_sec_reg` ✅ | ✅ |
| LOGITS | 0x040-0x05A | 27 × s16 sign-extend ✅ | 27 × s16 sign-extend ✅ | ✅ |

**读未映射地址**：DE1-SoC 返回 `0x00000000`（静默），ZCU106 返回 SLVERR（有错报）→ **改进**。

---

## 六、与历史经验文档的差异对比

| 经验教训 (TPU) | 移植文档是否遵循 | 备注 |
|---------------|-----------------|------|
| PS PL_CLK0 不需要外部时钟约束 | ✅ 已遵循 | 无 XDC create_clock |
| Board Preset 自动配置 DDR/UART | ✅ 已遵循 | apply_bd_automation |
| BD module reference 需 .v 文件 | ✅ 已遵循 | microgpt_top_fpga.v 是 Verilog-2001 |
| AXI 接口命名 HPM0_FPD | ✅ 已遵循 | 非旧版 M_AXI_GP0 |
| FCLK_CLK0 → pl_clk0 | ✅ 已遵循 | 新版命名 |
| WSL2 OOM 风险 | ❌ 未提及 | 移植文档无 WSL2 内存建议 |
| DRC override NSTD-1 | ✅ 已遵循 | TCL 中有 set_property SEVERITY |
| psu_init.tcl 备选方案 | ✅ 已遵循 | download 脚本有 fallback |

**WSL2 OOM 遗漏**：经验文档 6.5 节提到 PS+PL 构建比纯 PL 更吃内存，建议 `.wslconfig` 调整。移植文档完全没提，如果在 WSL2 下构建可能会 OOM。

---

## 七、tokens_per_sec 计算逻辑审查

```verilog
// microgpt_top_fpga.v 第 424-425 行
tokens_per_sec_reg <= (perf_cycles_reg > 0) ?
    (CORE_CLOCK_HZ / perf_cycles_reg) : 32'd0;
```

**计算方式**：`100,000,000 / 最后一个 token 的总周期数`

**问题**：`perf_cycles_reg` 从 `start` 到最后一个 `core_done` 的总累计周期，不是单个 token 的周期。结果是 `clock_freq / total_cycles`，即"如果每个 token 都这么快，每秒能生成多少个"。这是一个**瞬时吞吐量估算**，不是平均吞吐量。

**示例**：如果 5 个 token 共用 500,000 周期 → `100M / 500K = 200 tokens/sec`。这实际上是"5 个 token 的平均速度"而非"第 5 个 token 的瞬时速度"。

**结论**：与原 DE1-SoC 计算方式一致，语义上是"平均吞吐量"。文档中应注明这个含义。

---

## 八、总结与建议优先级

| 优先级 | 问题 | 影响 | 建议 |
|--------|------|------|------|
| 🔴 严重 | `max_gen_reg` 校验用旧值（非阻塞赋值 Bug） | 非法 max_gen 值可能被接受，导致不可预测行为 | 校验 `host_max_gen_reg` 而非 `max_gen_reg` |
| 🟡 中 | 文档写 64KB，实际 TCL 写 4KB | 文档误导 | 统一为 4KB |
| 🟡 中 | hex 文件过期不刷新 | 换模型权重后可能用旧 hex | 加时间戳比较或强制覆盖 |
| 🟡 中 | WSL2 OOM 建议缺失 | 构建可能失败 | 补充 .wslconfig 建议 |
| 🟢 低 | `REG_DISPLAY` 宏定义未使用 | 代码冗余 | 删除或注释 |
| 🟢 低 | tokens_per_sec 含义未在文档中说明 | 用户误解 | 注明是"平均吞吐量" |

---

## 九、第一轮 Review 纠正

第一轮 review 中有 **3 个判断错误**，已在本轮纠正：

| 第一轮判断 | 实际情况 | 纠正 |
|-----------|---------|------|
| "TCL 无 utilization 阈值门禁" | **有**（第 252-269 行，LUT >80% 则 exit 1） | 已纠正 |
| "TCL 无 WNS 时序门禁" | **有**（第 271-281 行，WNS <0 则 exit 1） | 已纠正 |
| "download 脚本无 bitstream 回读验证" | **有**（第 79-93 行，mrd 读 MAGIC 寄存器） | 已纠正 |

**原因**：第一轮 review 依赖 agent 摘要而非逐行阅读源码，导致遗漏了这些已实现的门禁。

---

**Reviewer**: Claude
**日期**: 2026-06-21
**版本**: v2（深度源码审查，纠正 v1 误判）
