// ============================================================================
// microgpt_ocm_bringup.c -- OCM-only baremetal bring-up for ZCU106
// ============================================================================
// Layered PS/UART/AXI4-Lite/PL verification path. This application is linked
// entirely into A53 OCM and only touches the microGPT register file.
// ============================================================================

#include <stdint.h>
#include "xil_io.h"
#include "xil_printf.h"
#include "sleep.h"

#define MICROGPT_BASE_ADDR      0xA0000000U

#define REG_MAGIC               (0x000U * 4U)
#define REG_VERSION             (0x001U * 4U)
#define REG_CONTROL             (0x002U * 4U)
#define REG_STATUS              (0x003U * 4U)
#define REG_CONFIG              (0x004U * 4U)
#define REG_SEED                (0x005U * 4U)
#define REG_DEBUG               (0x006U * 4U)
#define REG_BOS                 (0x007U * 4U)
#define REG_OUTPUT_BASE         (0x018U * 4U)
#define REG_PERF_CYCLES         (0x036U * 4U)
#define REG_TOKENS_PER_SEC      (0x037U * 4U)

#define STATUS_READY_BIT        (1U << 0)
#define STATUS_BUSY_BIT         (1U << 1)
#define STATUS_DONE_BIT         (1U << 2)
#define STATUS_ERROR_BIT        (1U << 3)
#define STATUS_OUT_LEN_SHIFT    16U
#define STATUS_POS_SHIFT        24U

#define EXPECTED_MAGIC          0x4D475254U
#define EXPECTED_VERSION        0x00020001U
#define EXPECTED_BOS            26U
#define TEMP_Q8_8_0P5           0x0080U
#define TEMP_Q8_8_1P0           0x0100U
#define POLL_LIMIT              1000000U
#define MAX_CAPTURE_TOKENS      16U

typedef struct {
    uint32_t status;
    uint32_t out_len;
    uint32_t pos;
    uint32_t perf_cycles;
    uint32_t debug;
    uint8_t tokens[MAX_CAPTURE_TOKENS];
} inference_result_t;

static uint32_t pass_count;
static uint32_t fail_count;

static inline uint32_t reg_read(uint32_t offset)
{
    return Xil_In32(MICROGPT_BASE_ADDR + offset);
}

static inline void reg_write(uint32_t offset, uint32_t value)
{
    Xil_Out32(MICROGPT_BASE_ADDR + offset, value);
}

static void check_u32(const char *name, uint32_t actual, uint32_t expected)
{
    if (actual == expected) {
        pass_count++;
        xil_printf("[PASS] %s = 0x%08lx\r\n", name, (unsigned long)actual);
    } else {
        fail_count++;
        xil_printf("[FAIL] %s = 0x%08lx expected 0x%08lx\r\n",
                   name, (unsigned long)actual, (unsigned long)expected);
    }
}

static void check_true(const char *name, uint32_t condition, uint32_t detail)
{
    if (condition != 0U) {
        pass_count++;
        xil_printf("[PASS] %s (0x%08lx)\r\n", name, (unsigned long)detail);
    } else {
        fail_count++;
        xil_printf("[FAIL] %s (0x%08lx)\r\n", name, (unsigned long)detail);
    }
}

static char token_to_char(uint8_t token)
{
    if (token < 26U) {
        return (char)('a' + token);
    }
    if (token == 26U) {
        return '.';
    }
    return '?';
}

static void print_tokens(const inference_result_t *result)
{
    uint32_t index;

    xil_printf("  Output text: \"");
    for (index = 0U; index < result->out_len && index < MAX_CAPTURE_TOKENS; index++) {
        xil_printf("%c", token_to_char(result->tokens[index]));
    }
    xil_printf("\"\r\n");

    xil_printf("  Token IDs: [");
    for (index = 0U; index < result->out_len && index < MAX_CAPTURE_TOKENS; index++) {
        if (index != 0U) {
            xil_printf(", ");
        }
        xil_printf("%lu", (unsigned long)result->tokens[index]);
    }
    xil_printf("]\r\n");
}

static void clear_and_wait_ready(void)
{
    uint32_t status;

    reg_write(REG_CONTROL, 0x00000002U);
    usleep(5000);
    status = reg_read(REG_STATUS);
    check_true("ready after clear", (status & STATUS_READY_BIT), status);
}

static int run_inference_case(const char *name,
                              uint32_t seed,
                              uint32_t temperature_q8_8,
                              uint32_t max_gen,
                              inference_result_t *result)
{
    uint32_t config;
    uint32_t poll;
    uint32_t index;

    xil_printf("\r\n[Test] %s\r\n", name);
    xil_printf("  seed=%lu temp_q8_8=0x%04lx max_gen=%lu\r\n",
               (unsigned long)seed,
               (unsigned long)temperature_q8_8,
               (unsigned long)max_gen);

    clear_and_wait_ready();

    config = ((temperature_q8_8 & 0xFFFFU) << 16) | ((max_gen & 0xFFU) << 8);
    reg_write(REG_CONFIG, config);
    reg_write(REG_SEED, seed);
    reg_write(REG_CONTROL, 0x00000001U);

    for (poll = 0U; poll < POLL_LIMIT; poll++) {
        result->status = reg_read(REG_STATUS);
        if ((result->status & STATUS_DONE_BIT) != 0U) {
            break;
        }
    }

    if (poll == POLL_LIMIT) {
        fail_count++;
        xil_printf("[FAIL] timeout status=0x%08lx\r\n", (unsigned long)result->status);
        return -1;
    }

    result->out_len = (result->status >> STATUS_OUT_LEN_SHIFT) & 0xFFU;
    result->pos = (result->status >> STATUS_POS_SHIFT) & 0xFFU;
    result->perf_cycles = reg_read(REG_PERF_CYCLES);
    result->debug = reg_read(REG_DEBUG);

    for (index = 0U; index < MAX_CAPTURE_TOKENS; index++) {
        result->tokens[index] = (uint8_t)(reg_read(REG_OUTPUT_BASE + index * 4U) & 0xFFU);
    }

    check_true("done bit set", (result->status & STATUS_DONE_BIT), result->status);
    check_true("error bit clear", ((result->status & STATUS_ERROR_BIT) == 0U), result->status);
    check_true("out_len within request", (result->out_len <= max_gen), result->out_len);
    check_true("out_len nonzero", (result->out_len > 0U), result->out_len);
    check_true("perf cycles nonzero", (result->perf_cycles > 0U), result->perf_cycles);

    xil_printf("  STATUS: 0x%08lx out_len=%lu pos=%lu\r\n",
               (unsigned long)result->status,
               (unsigned long)result->out_len,
               (unsigned long)result->pos);
    xil_printf("  PERF cycles: %lu\r\n", (unsigned long)result->perf_cycles);
    xil_printf("  DEBUG: 0x%08lx\r\n", (unsigned long)result->debug);
    print_tokens(result);

    return 0;
}

static uint32_t same_result(const inference_result_t *left, const inference_result_t *right)
{
    uint32_t index;

    if (left->out_len != right->out_len) {
        return 0U;
    }
    for (index = 0U; index < left->out_len && index < MAX_CAPTURE_TOKENS; index++) {
        if (left->tokens[index] != right->tokens[index]) {
            return 0U;
        }
    }
    return 1U;
}

static void test_register_connectivity(void)
{
    uint32_t magic;
    uint32_t version;
    uint32_t bos;

    xil_printf("\r\n[Test] register connectivity\r\n");
    magic = reg_read(REG_MAGIC);
    version = reg_read(REG_VERSION);
    bos = reg_read(REG_BOS) & 0xFFU;

    check_u32("MAGIC", magic, EXPECTED_MAGIC);
    check_u32("VERSION", version, EXPECTED_VERSION);
    check_u32("BOS token", bos, EXPECTED_BOS);
}

static void test_idle_config_defaults(void)
{
    uint32_t read_config;
    uint32_t read_seed;

    xil_printf("\r\n[Test] idle config defaults\r\n");
    clear_and_wait_ready();
    read_config = reg_read(REG_CONFIG);
    read_seed = reg_read(REG_SEED);

    check_u32("CONFIG default", read_config, ((TEMP_Q8_8_0P5 & 0xFFFFU) << 16) | (15U << 8));
    check_u32("SEED default", read_seed, 1U);
}

static void test_invalid_max_gen(void)
{
    uint32_t status;

    xil_printf("\r\n[Test] invalid max_gen is rejected\r\n");
    clear_and_wait_ready();
    reg_write(REG_CONFIG, (TEMP_Q8_8_0P5 << 16));
    reg_write(REG_SEED, 1U);
    reg_write(REG_CONTROL, 0x00000001U);
    usleep(5000);
    status = reg_read(REG_STATUS);

    check_true("done after invalid request", (status & STATUS_DONE_BIT), status);
    check_true("error after invalid request", (status & STATUS_ERROR_BIT), status);
}

int main(void)
{
    inference_result_t seed1_a;
    inference_result_t seed1_b;
    inference_result_t seed42;

    pass_count = 0U;
    fail_count = 0U;

    xil_printf("\r\n=== TALOS microGPT OCM-only Bring-up ===\r\n");
    xil_printf("Running from OCM (0xFFFC0000), no DDR dependency\r\n");
    xil_printf("PL base: 0x%08lx\r\n", (unsigned long)MICROGPT_BASE_ADDR);

    test_register_connectivity();
    clear_and_wait_ready();
    test_idle_config_defaults();
    test_invalid_max_gen();

    (void)run_inference_case("deterministic run A", 1U, TEMP_Q8_8_0P5, 4U, &seed1_a);
    (void)run_inference_case("deterministic run B", 1U, TEMP_Q8_8_0P5, 4U, &seed1_b);
    check_true("same seed reproduces tokens", same_result(&seed1_a, &seed1_b), seed1_b.out_len);

    (void)run_inference_case("different seed smoke", 42U, TEMP_Q8_8_0P5, 4U, &seed42);

    xil_printf("\r\nSUMMARY: %lu passed / %lu failed\r\n",
               (unsigned long)pass_count,
               (unsigned long)fail_count);
    if (fail_count == 0U) {
        xil_printf("RESULT: PASS\r\n");
    } else {
        xil_printf("RESULT: FAIL\r\n");
    }
    xil_printf("=== Done ===\r\n");

    return (fail_count == 0U) ? 0 : 1;
}
