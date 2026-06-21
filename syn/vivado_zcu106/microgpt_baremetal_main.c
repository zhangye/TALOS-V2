// ============================================================================
// microgpt_baremetal_main.c -- Bare-metal test for microGPT on ZCU106
// ============================================================================
// Runs on Cortex-A53 (standalone/RTOS). Accesses microGPT PL registers
// via memory-mapped AXI4-Lite at base address 0xA000_0000.
//
// Usage: program runs automatically on boot, or via xsdb:
//   xsdb> dow microgpt_baremetal_app.elf
//   xsdb> con
//
// UART output: 115200 8N1 (ZCU106 UART0 via MIO)
//
// Build: Vitis standalone application, import XSA from Vivado build.
//   Platform: standalone + psu_cortexa53_0
//   Template: Empty Application (C)
//
// Revision: 2026-06-21
// ============================================================================

#include <stdio.h>
#include <string.h>
#include "xil_io.h"
#include "xparameters.h"
#include "sleep.h"

// -----------------------------------------------------------------------
// Register Base Address (must match vivado_zcu106.tcl address assignment)
// -----------------------------------------------------------------------
#define MICROGPT_BASE_ADDR      0xA0000000

// Register offsets (byte-addressed, word_addr * 4)
#define REG_MAGIC               (0x000 * 4)
#define REG_VERSION             (0x001 * 4)
#define REG_CONTROL             (0x002 * 4)
#define REG_STATUS              (0x003 * 4)
#define REG_CONFIG              (0x004 * 4)
#define REG_SEED                (0x005 * 4)
#define REG_DEBUG               (0x006 * 4)
#define REG_BOS                 (0x007 * 4)
#define REG_STEP_CONFIG         (0x008 * 4)
#define REG_STEP_TRIGGER        (0x009 * 4)
#define REG_DISPLAY             (0x00A * 4)
#define REG_OUTPUT_BASE         (0x018 * 4)
#define REG_PERF_CYCLES         (0x036 * 4)
#define REG_TOKENS_PER_SEC      (0x037 * 4)
#define REG_LOGITS_BASE         (0x040 * 4)

// Status register bit positions
#define STATUS_READY_BIT        (1 << 0)
#define STATUS_BUSY_BIT         (1 << 1)
#define STATUS_DONE_BIT         (1 << 2)
#define STATUS_ERROR_BIT        (1 << 3)
#define STATUS_HOST_TOGGLE_BIT  (1 << 4)
#define STATUS_DIRECT_MODE_BIT  (1 << 5)
#define STATUS_OUT_LEN_SHIFT    16
#define STATUS_OUT_LEN_MASK     0xFF
#define STATUS_POS_SHIFT        24
#define STATUS_POS_MASK         0xFF

// Token decoding
#define BOS_TOKEN               26
#define VOCAB_SIZE              27
#define MAX_OUTPUT_TOKENS       16

// -----------------------------------------------------------------------
// Helper: read/write registers
// -----------------------------------------------------------------------
static inline u32 reg_read(u32 offset) {
    return Xil_In32(MICROGPT_BASE_ADDR + offset);
}

static inline void reg_write(u32 offset, u32 value) {
    Xil_Out32(MICROGPT_BASE_ADDR + offset, value);
}

// -----------------------------------------------------------------------
// Token to character conversion (same as microGPT Python/RTL mapping)
// -----------------------------------------------------------------------
static char token_to_char(u8 token) {
    if (token == BOS_TOKEN) return '\0';
    if (token < 26) return 'a' + (char)token;
    return '?';
}

// -----------------------------------------------------------------------
// Wait for status register to have specified bits set
// Returns 0 on success, -1 on timeout
// -----------------------------------------------------------------------
static int wait_for_status(u32 mask, u32 expected, int timeout_ms) {
    while (timeout_ms > 0) {
        u32 status = reg_read(REG_STATUS);
        if ((status & mask) == expected)
            return 0;
        usleep(1000); // 1ms
        timeout_ms--;
    }
    return -1;
}

// -----------------------------------------------------------------------
// Run inference: write config, trigger, wait for done, read results
// -----------------------------------------------------------------------
static int run_inference(u32 seed, u32 temperature_q8_8, u32 max_gen) {
    u32 status;
    u32 config_word;
    int i;

    printf("\r\n=== microGPT Inference on ZCU106 ===\r\n");
    printf("Seed:        %u\r\n", seed);
    printf("Temperature: Q8.8 = 0x%04X (%.4f)\r\n",
           temperature_q8_8, (double)temperature_q8_8 / 256.0);
    printf("Max tokens:  %u\r\n", max_gen);

    // Read hardware ID
    u32 magic = reg_read(REG_MAGIC);
    u32 version = reg_read(REG_VERSION);
    printf("Magic:       0x%08X", magic);
    if (magic == 0x4D475254)
        printf(" ('MGRT' OK)");
    else
        printf(" (UNEXPECTED!)");
    printf("\r\n");
    printf("Version:     0x%08X\r\n", version);

    // Wait for ready
    printf("Waiting for ready...\r\n");
    if (wait_for_status(STATUS_READY_BIT, STATUS_READY_BIT, 5000) != 0) {
        printf("ERROR: Timeout waiting for ready\r\n");
        return -1;
    }

    // Write config: {temperature[15:0], max_gen[7:0], 8'd0}
    config_word = ((temperature_q8_8 & 0xFFFF) << 16) | ((max_gen & 0xFF) << 8);
    reg_write(REG_CONFIG, config_word);
    printf("Config:      0x%08X\r\n", config_word);

    // Write seed
    reg_write(REG_SEED, seed);
    printf("Seed reg:    0x%08X\r\n", seed);

    // Trigger inference: write bit0 of control register
    reg_write(REG_CONTROL, 0x00000001);
    printf("Inference started...\r\n");

    // Wait for done (poll status register)
    // Timeout: generous for hardware inference
    int poll_count = 0;
    while (1) {
        status = reg_read(REG_STATUS);
        if (status & STATUS_DONE_BIT)
            break;
        if (status & STATUS_ERROR_BIT) {
            printf("ERROR: Hardware error flag set (status=0x%08X)\r\n", status);
            return -1;
        }
        poll_count++;
        if (poll_count > 100000) {
            printf("ERROR: Timeout waiting for done (status=0x%08X)\r\n", status);
            return -1;
        }
        usleep(100); // 100us
    }

    // Read results
    u32 out_len = (status >> STATUS_OUT_LEN_SHIFT) & STATUS_OUT_LEN_MASK;
    u32 pos = (status >> STATUS_POS_SHIFT) & STATUS_POS_MASK;
    u32 perf_cycles = reg_read(REG_PERF_CYCLES);
    u32 debug = reg_read(REG_DEBUG);

    // Compute throughput in SW (HW does not have a divider)
    u32 tokens_sec = (perf_cycles > 0) ? (100000000 / perf_cycles) : 0;
    double time_ms = (perf_cycles > 0) ? ((double)perf_cycles / 100000.0) : 0.0;

    printf("\r\n--- Results ---\r\n");
    printf("Status:      0x%08X\r\n", status);
    printf("Output len:  %u tokens\r\n", out_len);
    printf("Position:    %u\r\n", pos);
    printf("Perf cycles: %u\r\n", perf_cycles);
    printf("Inference:   %.2f ms\r\n", time_ms);
    printf("Tokens/sec:  %u\r\n", tokens_sec);
    printf("Debug:       0x%08X (last_token=%u, argmax=%u, top_logit=0x%04X)\r\n",
           debug,
           debug & 0xFF,
           (debug >> 8) & 0xFF,
           (debug >> 16) & 0xFFFF);

    // Read and decode output tokens
    printf("Output text: \"");
    char output_str[MAX_OUTPUT_TOKENS + 1];
    memset(output_str, 0, sizeof(output_str));

    for (i = 0; i < (int)out_len && i < MAX_OUTPUT_TOKENS; i++) {
        u32 token_word = reg_read(REG_OUTPUT_BASE + i * 4);
        u8 token = token_word & 0xFF;
        char c = token_to_char(token);
        output_str[i] = c;
        if (c != '\0')
            printf("%c", c);
    }
    printf("\"\r\n");

    // Print raw token IDs
    printf("Token IDs:   [");
    for (i = 0; i < (int)out_len && i < MAX_OUTPUT_TOKENS; i++) {
        u32 token_word = reg_read(REG_OUTPUT_BASE + i * 4);
        if (i > 0) printf(", ");
        printf("%u", token_word & 0xFF);
    }
    printf("]\r\n");

    // Print raw logits
    printf("Raw logits:  [");
    for (i = 0; i < VOCAB_SIZE; i++) {
        u32 logit_word = reg_read(REG_LOGITS_BASE + i * 4);
        s16 logit = (s16)(logit_word & 0xFFFF);
        if (i > 0) printf(", ");
        printf("%d", logit);
    }
    printf("]\r\n");

    printf("=== Done ===\r\n\r\n");
    return 0;
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main() {
    // PS startup heartbeat: confirms UART and PS clocks are working
    printf("\r\n[PS] Boot OK. Clocks and UART initialized.\r\n");
    printf("\r\n");
    printf("============================================\r\n");
    printf(" microGPT ZCU106 Bare-Metal Test\r\n");
    printf(" PL Base: 0x%08X\r\n", MICROGPT_BASE_ADDR);
    printf("============================================\r\n");

    // Test 1: Basic connectivity
    printf("\r\n[Test 1] Register connectivity\r\n");
    u32 magic = reg_read(REG_MAGIC);
    u32 version = reg_read(REG_VERSION);
    u32 bos = reg_read(REG_BOS);

    printf("  Magic:   0x%08X", magic);
    if (magic == 0x4D475254)
        printf(" -- PASS\r\n");
    else {
        printf(" -- FAIL (expected 0x4D475254)\r\n");
        printf("  Check: bitstream programmed? Address map correct?\r\n");
        return -1;
    }

    printf("  Version: 0x%08X\r\n", version);
    printf("  BOS:     0x%08X (token=%u)\r\n", bos, bos & 0xFF);

    // Test 2: Clear and verify ready
    printf("\r\n[Test 2] Clear and verify ready\r\n");
    reg_write(REG_CONTROL, 0x00000002); // bit1 = clear
    usleep(1000);
    u32 status = reg_read(REG_STATUS);
    printf("  Status after clear: 0x%08X", status);
    if (status & STATUS_READY_BIT)
        printf(" -- PASS (ready)\r\n");
    else
        printf(" -- WARN (not ready, may need time)\r\n");

    // Test 3: Run inference with default parameters
    // Expected output for seed=1, temperature=0.5 (Q8.8=0x0080), max_gen=15:
    //   Token sequence: [10, 4, 11, 24, 13, ...] (deterministic)
    printf("\r\n[Test 3] Inference run\r\n");
    run_inference(
        1,      // seed
        0x0080, // temperature Q8.8 (0.5)
        15      // max_gen
    );

    // Test 4: Second run (different seed)
    printf("\r\n[Test 4] Inference run (seed=42)\r\n");
    reg_write(REG_CONTROL, 0x00000002); // clear
    usleep(1000);
    run_inference(
        42,     // seed
        0x0080, // temperature Q8.8 (0.5)
        15      // max_gen
    );

    printf("\r\nAll tests complete.\r\n");
    return 0;
}
