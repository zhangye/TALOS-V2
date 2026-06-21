// ============================================================================
// microgpt_top_fpga.v -- FPGA Wrapper for PS+PL Block Design (ZCU106)
// ============================================================================
// Verilog-2001 wrapper for microgpt_exact_core, compatible with Vivado
// Block Design module reference (requires .v file type).
//
//   - AXI4-Lite slave: connects to PS M_AXI_HPM0_FPD via SmartConnect
//   - Clock/reset: from PS pl_clk0 / pl_resetn0 (single clock domain)
//   - IRQ: output to PS pl_ps_irq0 (pulse on inference done)
//
// Register map identical to de1_soc_microgpt_rtl.sv (word-addressed).
// Base address in PS address space: 0xA000_0000 (64KB).
//
// Revision: 2026-06-21
// ============================================================================

module microgpt_top_fpga (
    // Clock and Reset from PS
    input  wire         aclk,
    input  wire         aresetn,

    // AXI4-Lite Slave (from PS M_AXI_GP0 via SmartConnect)
    input  wire [31:0]  s_axi_awaddr,
    input  wire [2:0]   s_axi_awprot,
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,
    output wire [1:0]   s_axi_bresp,
    output wire         s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [31:0]  s_axi_araddr,
    input  wire [2:0]   s_axi_arprot,
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    output wire [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready,

    // Interrupt output (to PS pl_ps_irq0)
    output wire         irq
);

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------
    localparam [7:0]  BOS_TOKEN         = 8'd26;
    localparam [2:0]  ST_READY          = 3'd0;
    localparam [2:0]  ST_WAIT_CORE      = 3'd1;
    localparam [2:0]  ST_DONE           = 3'd2;
    // Note: CORE_CLOCK_HZ is documented for SW-side throughput calculation.
// HW does NOT perform division (32-bit divider causes timing failure at 100MHz).
// SW computes: tokens_per_sec = CORE_CLOCK_HZ / perf_cycles_reg

    // -----------------------------------------------------------------------
    // AXI4-Lite Internal Signals
    // -----------------------------------------------------------------------
    reg         axi_awready;
    reg         axi_wready;
    reg         axi_bvalid;
    reg [31:0]  axi_araddr;
    reg         axi_arready;
    reg [31:0]  axi_rdata;
    reg         axi_rvalid;

    reg         write_en;
    reg         wr_addr_valid;
    reg [11:0]  wr_addr_latched;
    reg         wr_data_valid;
    reg [31:0]  wr_data_latched;

    wire [9:0]  word_addr_w = wr_addr_latched[11:2];
    wire [9:0]  word_addr_r = axi_araddr[11:2];

    // -----------------------------------------------------------------------
    // Core Control Registers
    // -----------------------------------------------------------------------
    reg  [2:0]  state_reg;
    reg  [7:0]  token_reg;
    reg  [7:0]  pos_reg;
    reg  [7:0]  out_len_reg;
    reg  [31:0] rng_reg;
    reg  [15:0] temperature_reg;
    reg  [7:0]  max_gen_reg;
    reg         start_core_reg;
    reg         clear_cache_reg;
    reg         done_latched_reg;
    reg  [7:0]  last_token_reg;
    reg  [7:0]  output_mem [0:15];
    reg  [31:0] perf_cycles_reg;
    reg  [31:0] tokens_per_sec_reg;
    reg         error_reg;
    reg         direct_mode_reg;
    reg         step_clear_reg;
    reg  [7:0]  step_token_reg;
    reg  [7:0]  step_pos_reg;

    // -----------------------------------------------------------------------
    // Host Request Signals (directly in aclk domain, no CDC needed)
    // -----------------------------------------------------------------------
    reg         host_start_req;
    reg         host_clear_req;
    reg         host_step_req;
    reg  [31:0] host_seed_reg;
    reg  [15:0] host_temperature_reg;
    reg  [7:0]  host_max_gen_reg;
    reg         host_direct_mode;
    reg         host_step_clear;
    reg  [7:0]  host_step_token;
    reg  [7:0]  host_step_pos;

    // -----------------------------------------------------------------------
    // Core Status Signals
    // -----------------------------------------------------------------------
    wire        core_busy;
    wire        core_done;
    wire [7:0]  core_next_token;
    wire [7:0]  core_argmax_token;
    wire [31:0] core_rng_state;
    wire signed [15:0] core_top_logit;
    wire signed [(27*16)-1:0] core_logits_flat;

    integer out_i;

    // Interrupt: active-high pulse on done
    assign irq = done_latched_reg;

    // -----------------------------------------------------------------------
    // AXI4-Lite Output Assignments
    // -----------------------------------------------------------------------
    reg         read_err;
    reg         write_err;

    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bresp   = write_err ? 2'b10 : 2'b00; // SLVERR or OKAY
    assign s_axi_bvalid  = axi_bvalid;
    assign s_axi_arready = axi_arready;
    assign s_axi_rdata   = axi_rdata;
    assign s_axi_rresp   = read_err  ? 2'b10 : 2'b00; // SLVERR or OKAY
    assign s_axi_rvalid  = axi_rvalid;

    // -----------------------------------------------------------------------
    // AXI4-Lite Write Channel (correct protocol handling)
    // -----------------------------------------------------------------------
    // AW and W channels are independent; latch each when valid & ready.
    // Once both latched, pulse write_en for one cycle, then assert B.
    always @(posedge aclk) begin
        if (!aresetn) begin
            axi_awready   <= 1'b0;
            axi_wready    <= 1'b0;
            axi_bvalid    <= 1'b0;
            write_en      <= 1'b0;
            wr_addr_valid <= 1'b0;
            wr_addr_latched <= 12'd0;
            wr_data_valid <= 1'b0;
            wr_data_latched <= 32'd0;
            write_err     <= 1'b0;
        end else begin
            write_en <= 1'b0;

            // Write address handshake: accept when valid and not yet latched
            if (s_axi_awvalid && ~wr_addr_valid) begin
                axi_awready     <= 1'b1;
                wr_addr_valid   <= 1'b1;
                wr_addr_latched <= s_axi_awaddr[11:0];
            end else begin
                axi_awready <= 1'b0;
            end

            // Write data handshake: accept when valid and not yet latched
            if (s_axi_wvalid && ~wr_data_valid) begin
                axi_wready      <= 1'b1;
                wr_data_valid   <= 1'b1;
                wr_data_latched <= s_axi_wdata;
            end else begin
                axi_wready <= 1'b0;
            end

            // Both channels captured → pulse write_en, clear latches
            if (wr_addr_valid && wr_data_valid && ~axi_bvalid) begin
                write_en      <= 1'b1;
                wr_addr_valid <= 1'b0;
                wr_data_valid <= 1'b0;
                write_err     <= ~wr_addr_mapped; // SLVERR for unmapped writes
                axi_bvalid    <= 1'b1;
            end

            // B channel handshake
            if (axi_bvalid && s_axi_bready) begin
                axi_bvalid <= 1'b0;
                write_err  <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // AXI4-Lite Read Channel (correct protocol handling)
    // -----------------------------------------------------------------------
    // AR accepted when valid & ready.  rvalid asserted next cycle regardless
    // of whether master keeps arvalid high (AXI4-Lite spec: arvalid may
    // deassert after handshake).
    reg rd_pending;

    always @(posedge aclk) begin
        if (!aresetn) begin
            axi_arready <= 1'b0;
            axi_araddr  <= 32'd0;
            axi_rvalid  <= 1'b0;
            axi_rdata   <= 32'd0;
            rd_pending  <= 1'b0;
        end else begin
            // Accept read address
            if (s_axi_arvalid && ~rd_pending && ~axi_rvalid) begin
                axi_arready <= 1'b1;
                axi_araddr  <= s_axi_araddr;
                rd_pending  <= 1'b1;
            end else begin
                axi_arready <= 1'b0;
            end

            // Present read data one cycle after address captured
            if (rd_pending && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rdata  <= read_data_comb;
                rd_pending <= 1'b0;
            end else if (axi_rvalid && s_axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // AXI4-Lite Write Handler (Register Writes)
    // -----------------------------------------------------------------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            host_seed_reg        <= 32'h00000001;
            host_temperature_reg <= 16'h0080;
            host_max_gen_reg     <= 8'd15;
            host_start_req       <= 1'b0;
            host_clear_req       <= 1'b0;
            host_step_req        <= 1'b0;
            host_direct_mode     <= 1'b0;
            host_step_clear      <= 1'b0;
            host_step_token      <= BOS_TOKEN;
            host_step_pos        <= 8'd0;
        end else begin
            // Clear single-cycle request pulses
            host_start_req <= 1'b0;
            host_clear_req <= 1'b0;
            host_step_req  <= 1'b0;

            if (write_en) begin
                case (word_addr_w)
                    10'h002: begin
                        if (wr_data_latched[0])
                            host_start_req <= 1'b1;
                        if (wr_data_latched[1])
                            host_clear_req <= 1'b1;
                    end
                    10'h004: begin
                        host_max_gen_reg     <= wr_data_latched[15:8];
                        host_temperature_reg <= wr_data_latched[31:16];
                    end
                    10'h005: begin
                        host_seed_reg <= wr_data_latched;
                    end
                    10'h008: begin
                        host_direct_mode <= wr_data_latched[0];
                        host_step_clear  <= wr_data_latched[1];
                        host_step_pos    <= wr_data_latched[15:8];
                        host_step_token  <= wr_data_latched[23:16];
                    end
                    10'h009: begin
                        if (wr_data_latched[0])
                            host_step_req <= 1'b1;
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

    // -----------------------------------------------------------------------
    // microgpt_exact_core Instance
    // -----------------------------------------------------------------------
    microgpt_exact_core core_inst (
        .clk              (aclk),
        .resetn           (aresetn),
        .start            (start_core_reg),
        .clear_cache      (clear_cache_reg),
        .sample_mode      (~direct_mode_reg),
        .temperature_q8_8 (temperature_reg),
        .rng_state_in     (rng_reg),
        .token_in         (token_reg),
        .pos_in           (pos_reg),
        .busy             (core_busy),
        .done             (core_done),
        .next_token       (core_next_token),
        .argmax_token     (core_argmax_token),
        .rng_state_out    (core_rng_state),
        .top_logit_q12    (core_top_logit),
        .logits_flat      (core_logits_flat)
    );

    // -----------------------------------------------------------------------
    // Generation Control FSM (single clock domain, no CDC)
    // -----------------------------------------------------------------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            state_reg         <= ST_READY;
            token_reg         <= BOS_TOKEN;
            pos_reg           <= 8'd0;
            out_len_reg       <= 8'd0;
            rng_reg           <= 32'h00000001;
            temperature_reg   <= 16'h0080;
            max_gen_reg       <= 8'd15;
            start_core_reg    <= 1'b0;
            clear_cache_reg   <= 1'b0;
            done_latched_reg  <= 1'b0;
            last_token_reg    <= 8'd0;
            perf_cycles_reg   <= 32'd0;
            tokens_per_sec_reg<= 32'd0;
            error_reg         <= 1'b0;
            direct_mode_reg   <= 1'b0;
            step_clear_reg    <= 1'b0;
            step_token_reg    <= BOS_TOKEN;
            step_pos_reg      <= 8'd0;
            for (out_i = 0; out_i < 16; out_i = out_i + 1)
                output_mem[out_i] <= 8'd0;
        end else begin
            start_core_reg  <= 1'b0;
            clear_cache_reg <= 1'b0;

            if (state_reg == ST_WAIT_CORE)
                perf_cycles_reg <= perf_cycles_reg + 32'd1;

            if (host_clear_req) begin
                state_reg         <= ST_READY;
                token_reg         <= BOS_TOKEN;
                pos_reg           <= 8'd0;
                out_len_reg       <= 8'd0;
                done_latched_reg  <= 1'b0;
                last_token_reg    <= 8'd0;
                perf_cycles_reg   <= 32'd0;
                tokens_per_sec_reg<= 32'd0;
                error_reg         <= 1'b0;
                direct_mode_reg   <= 1'b0;
                for (out_i = 0; out_i < 16; out_i = out_i + 1)
                    output_mem[out_i] <= 8'd0;
            end else begin
                // Latch step config from host when step request fires
                if (host_step_req) begin
                    direct_mode_reg <= host_direct_mode;
                    step_clear_reg  <= host_step_clear;
                    step_token_reg  <= host_step_token;
                    step_pos_reg    <= host_step_pos;
                end

                case (state_reg)
                    ST_READY: begin
                        if (host_step_req && host_direct_mode) begin
                            token_reg        <= host_step_token;
                            pos_reg          <= host_step_pos;
                            out_len_reg      <= 8'd0;
                            done_latched_reg <= 1'b0;
                            last_token_reg   <= 8'd0;
                            perf_cycles_reg  <= 32'd0;
                            tokens_per_sec_reg <= 32'd0;
                            error_reg        <= 1'b0;
                            if (host_step_clear)
                                rng_reg <= host_seed_reg;
                            clear_cache_reg <= host_step_clear;
                            start_core_reg  <= 1'b1;
                            state_reg       <= ST_WAIT_CORE;
                        end else if (host_start_req) begin
                            token_reg        <= BOS_TOKEN;
                            pos_reg          <= 8'd0;
                            out_len_reg      <= 8'd0;
                            done_latched_reg <= 1'b0;
                            last_token_reg   <= 8'd0;
                            perf_cycles_reg  <= 32'd0;
                            tokens_per_sec_reg <= 32'd0;
                            error_reg        <= 1'b0;
                            for (out_i = 0; out_i < 16; out_i = out_i + 1)
                                output_mem[out_i] <= 8'd0;
                            max_gen_reg      <= host_max_gen_reg;
                            temperature_reg  <= host_temperature_reg;
                            rng_reg          <= host_seed_reg;
                            direct_mode_reg  <= 1'b0;
                            clear_cache_reg  <= 1'b1;
                            if (host_max_gen_reg == 8'd0 || host_max_gen_reg > 8'd15) begin
                                error_reg        <= 1'b1;
                                done_latched_reg <= 1'b1;
                                state_reg        <= ST_DONE;
                            end else begin
                                start_core_reg <= 1'b1;
                                state_reg      <= ST_WAIT_CORE;
                            end
                        end
                    end

                    ST_WAIT_CORE: begin
                        if (core_done) begin
                            rng_reg        <= core_rng_state;
                            last_token_reg <= core_next_token;
                            if (direct_mode_reg) begin
                                done_latched_reg <= 1'b1;
                                state_reg        <= ST_DONE;
                            end else if ((core_next_token == BOS_TOKEN) || (pos_reg == 8'd15)) begin
                                done_latched_reg <= 1'b1;
                                state_reg        <= ST_DONE;
                            end else begin
                                output_mem[out_len_reg] <= core_next_token;
                                token_reg   <= core_next_token;
                                pos_reg     <= pos_reg + 8'd1;
                                out_len_reg <= out_len_reg + 8'd1;
                                if ((out_len_reg + 8'd1) >= max_gen_reg) begin
                                    done_latched_reg <= 1'b1;
                                    state_reg        <= ST_DONE;
                                end else begin
                                    start_core_reg <= 1'b1;
                                    state_reg      <= ST_WAIT_CORE;
                                end
                            end
                        end
                    end

                    ST_DONE: begin
                        if (host_step_req && host_direct_mode) begin
                            token_reg        <= host_step_token;
                            pos_reg          <= host_step_pos;
                            out_len_reg      <= 8'd0;
                            done_latched_reg <= 1'b0;
                            last_token_reg   <= 8'd0;
                            perf_cycles_reg  <= 32'd0;
                            tokens_per_sec_reg <= 32'd0;
                            error_reg        <= 1'b0;
                            if (host_step_clear)
                                rng_reg <= host_seed_reg;
                            clear_cache_reg <= host_step_clear;
                            start_core_reg  <= 1'b1;
                            state_reg       <= ST_WAIT_CORE;
                        end else if (host_start_req) begin
                            token_reg        <= BOS_TOKEN;
                            pos_reg          <= 8'd0;
                            out_len_reg      <= 8'd0;
                            done_latched_reg <= 1'b0;
                            last_token_reg   <= 8'd0;
                            perf_cycles_reg  <= 32'd0;
                            tokens_per_sec_reg <= 32'd0;
                            error_reg        <= 1'b0;
                            for (out_i = 0; out_i < 16; out_i = out_i + 1)
                                output_mem[out_i] <= 8'd0;
                            max_gen_reg      <= host_max_gen_reg;
                            temperature_reg  <= host_temperature_reg;
                            rng_reg          <= host_seed_reg;
                            direct_mode_reg  <= 1'b0;
                            clear_cache_reg  <= 1'b1;
                            if (host_max_gen_reg == 8'd0 || host_max_gen_reg > 8'd15) begin
                                error_reg        <= 1'b1;
                                done_latched_reg <= 1'b1;
                                state_reg        <= ST_DONE;
                            end else begin
                                start_core_reg <= 1'b1;
                                state_reg      <= ST_WAIT_CORE;
                            end
                        end
                    end

                    default: state_reg <= ST_READY;
                endcase
            end
        end
    end

    // -----------------------------------------------------------------------
    // Register Read MUX (combinational)
    // -----------------------------------------------------------------------
    reg [31:0] read_data_comb;

    // Address validation for SLVERR response
    wire wr_addr_mapped = (word_addr_w == 10'h002) || (word_addr_w == 10'h004) ||
                          (word_addr_w == 10'h005) || (word_addr_w == 10'h008) ||
                          (word_addr_w == 10'h009) || (word_addr_w == 10'h00A);

    always @(*) begin
        read_data_comb = 32'd0;
        read_err = 1'b0;
        case (word_addr_r)
            10'h000: read_data_comb = 32'h4D475254; // "MGRT"
            10'h001: read_data_comb = 32'h00020001; // version
            10'h003: read_data_comb = {
                pos_reg,
                out_len_reg,
                8'd0,
                2'd0,
                direct_mode_reg,
                1'b0,           // host_toggle (not used in PS+PL)
                error_reg,
                done_latched_reg,
                (state_reg == ST_WAIT_CORE),
                (state_reg == ST_READY)
            };
            10'h004: read_data_comb = {temperature_reg, max_gen_reg, 8'd0};
            10'h005: read_data_comb = rng_reg;
            10'h006: read_data_comb = {core_top_logit[15:0], core_argmax_token, last_token_reg};
            10'h007: read_data_comb = {16'd0, 8'd0, BOS_TOKEN};
            10'h008: read_data_comb = {8'd0, step_token_reg, step_pos_reg, step_clear_reg, direct_mode_reg};
            10'h036: read_data_comb = perf_cycles_reg;
            10'h037: read_data_comb = tokens_per_sec_reg;
            default: begin
                // Output token memory: word 0x018..0x027
                if ((word_addr_r >= 10'h018) && (word_addr_r < 10'h028))
                    read_data_comb = {24'd0, output_mem[word_addr_r - 10'h018]};
                // Raw logits: word 0x040..0x05A
                else if ((word_addr_r >= 10'h040) && (word_addr_r < (10'h040 + 10'd27)))
                    read_data_comb = {{16{core_logits_flat[((word_addr_r - 10'h040)*16)+15]}},
                                      core_logits_flat[((word_addr_r - 10'h040)*16) +: 16]};
                else
                    read_err = 1'b1; // Unmapped address → SLVERR
            end
        endcase
    end

endmodule
