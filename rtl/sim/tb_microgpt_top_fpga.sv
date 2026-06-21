// ============================================================================
// tb_microgpt_top_fpga.sv — AXI4-Lite Wrapper Testbench
// ============================================================================
// Tests:
//   1. AXI4-Lite read/write protocol correctness
//   2. Register map (MAGIC, VERSION, CONFIG, SEED, STATUS, OUTPUT)
//   3. FSM control flow: start → wait_core → done
//   4. max_gen validation (host_max_gen_reg, not stale max_gen_reg)
//   5. Deterministic output sequence [10, 4, 11, 24, 13]
//   6. Clear and re-run
// ============================================================================

`timescale 1ns/1ps

module tb_microgpt_top_fpga;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam BASE_ADDR = 32'hA000_0000;
    localparam REG_MAGIC     = BASE_ADDR + 32'h000;
    localparam REG_VERSION   = BASE_ADDR + 32'h004;
    localparam REG_CONTROL   = BASE_ADDR + 32'h008;
    localparam REG_STATUS    = BASE_ADDR + 32'h00C;
    localparam REG_CONFIG    = BASE_ADDR + 32'h010;
    localparam REG_SEED      = BASE_ADDR + 32'h014;
    localparam REG_DEBUG     = BASE_ADDR + 32'h018;
    localparam REG_BOS       = BASE_ADDR + 32'h01C;
    localparam REG_OUTPUT    = BASE_ADDR + 32'h060;
    localparam REG_PERF      = BASE_ADDR + 32'h0D8;
    localparam REG_TOKSEC    = BASE_ADDR + 32'h0DC;

    // -----------------------------------------------------------------------
    // Signals
    // -----------------------------------------------------------------------
    reg         aclk;
    reg         aresetn;

    // AXI4-Lite
    reg  [31:0] s_axi_awaddr;
    reg  [2:0]  s_axi_awprot;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;
    reg  [31:0] s_axi_araddr;
    reg  [2:0]  s_axi_arprot;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    wire        irq;

    // Test control
    integer errors;
    integer test_num;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    microgpt_top_fpga dut (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awprot   (s_axi_awprot),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arprot   (s_axi_arprot),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready),
        .irq            (irq)
    );

    // Clock: 100 MHz
    initial aclk = 0;
    always #5 aclk = ~aclk;

    // -----------------------------------------------------------------------
    // AXI4-Lite Bus Tasks
    // -----------------------------------------------------------------------
    task automatic axi_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            // Drive AW and W simultaneously
            @(posedge aclk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;

            // Wait for both AW and W accepted
            fork
                begin
                    while (!(s_axi_awready && s_axi_awvalid)) @(posedge aclk);
                    s_axi_awvalid <= 1'b0;
                end
                begin
                    while (!(s_axi_wready && s_axi_wvalid)) @(posedge aclk);
                    s_axi_wvalid <= 1'b0;
                end
            join

            // Wait for B response
            while (!(s_axi_bvalid && s_axi_bready)) @(posedge aclk);

            if (s_axi_bresp != 2'b00)
                $display("WARNING: BRESP=%0d at addr=0x%08X (expected OKAY)", s_axi_bresp, addr);

            @(posedge aclk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task automatic axi_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge aclk);
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;

            // Wait for AR accepted
            while (!(s_axi_arready && s_axi_arvalid)) @(posedge aclk);
            s_axi_arvalid <= 1'b0;

            // Wait for R valid
            while (!(s_axi_rvalid && s_axi_rready)) @(posedge aclk);
            data = s_axi_rdata;

            if (s_axi_rresp != 2'b00)
                $display("WARNING: RRESP=%0d at addr=0x%08X (expected OKAY)", s_axi_rresp, addr);

            @(posedge aclk);
            s_axi_rready <= 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Check Helper
    // -----------------------------------------------------------------------
    task automatic check_str;
        input integer   cond;
        input string    name;
        input string    detail;
        begin
            if (cond)
                $display("  [PASS] %0s", name);
            else begin
                $display("  [FAIL] %0s -- %0s", name, detail);
                errors = errors + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Wait for STATUS bits
    // -----------------------------------------------------------------------
    task automatic wait_status_done;
        input integer timeout_cycles;
        integer i;
        reg [31:0] status;
        begin
            for (i = 0; i < timeout_cycles; i = i + 1) begin
                axi_read(REG_STATUS, status);
                if (status[2]) begin // done bit
                    i = timeout_cycles; // break
                end
                if (status[3]) begin // error bit
                    $display("  ERROR flag set in STATUS=0x%08X", status);
                    errors = errors + 1;
                    i = timeout_cycles;
                end
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Main Test Sequence
    // -----------------------------------------------------------------------
    reg [31:0] rdata;
    reg [31:0] status;
    integer    i;

    initial begin
        errors = 0;
        test_num = 0;

        // Init AXI signals
        s_axi_awaddr  = 0; s_axi_awprot = 0; s_axi_awvalid = 0;
        s_axi_wdata   = 0; s_axi_wstrb  = 0; s_axi_wvalid  = 0;
        s_axi_bready  = 0;
        s_axi_araddr  = 0; s_axi_arprot = 0; s_axi_arvalid = 0;
        s_axi_rready  = 0;

        // Reset
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

        // ================================================================
        // Test 1: Register Connectivity
        // ================================================================
        test_num = 1;
        $display("\n=== Test %0d: Register Connectivity ===", test_num);

        axi_read(REG_MAGIC, rdata);
        check_str("MAGIC = 0x4D475254", rdata === 32'h4D475254, $sformatf("got 0x%08X", rdata));

        axi_read(REG_VERSION, rdata);
        check_str("VERSION = 0x00020001", rdata === 32'h00020001, $sformatf("got 0x%08X", rdata));

        axi_read(REG_BOS, rdata);
        check_str("BOS = 26", (rdata & 32'hFF) === 32'd26, $sformatf("got %0d", rdata & 32'hFF));

        // ================================================================
        // Test 2: Register Read/Write
        // ================================================================
        test_num = 2;
        $display("\n=== Test %0d: Register Read/Write ===", test_num);

        // Write SEED, read back
        axi_write(REG_SEED, 32'hDEADBEEF);
        axi_read(REG_SEED, rdata);
        check_str("SEED readback 0xDEADBEEF", rdata === 32'hDEADBEEF, $sformatf("got 0x%08X", rdata));

        // Write CONFIG, read back
        // CONFIG = {temperature[15:0], max_gen[7:0], 8'd0}
        // temp=0x0080, max_gen=15 → 0x00800F00
        axi_write(REG_CONFIG, 32'h0080_0F_00);
        axi_read(REG_CONFIG, rdata);
        check_str("CONFIG readback 0x00800F00", rdata === 32'h00800F00, $sformatf("got 0x%08X", rdata));

        // ================================================================
        // Test 3: Clear and Ready
        // ================================================================
        test_num = 3;
        $display("\n=== Test %0d: Clear and Ready ===", test_num);

        axi_write(REG_CONTROL, 32'h00000002); // bit1 = clear
        repeat (5) @(posedge aclk);
        axi_read(REG_STATUS, status);
        check_str("STATUS ready=1 after clear", status[0] === 1'b1, $sformatf("STATUS=0x%08X", status));

        // ================================================================
        // Test 4: Inference Run (seed=2, max_gen=15)
        // Expected deterministic output: [10, 4, 11, 24, 13]
        // ================================================================
        test_num = 4;
        $display("\n=== Test %0d: Inference Run (seed=2) ===", test_num);

        // Configure
        axi_write(REG_CONFIG, 32'h0080_0F_00); // temp=0.5, max_gen=15
        axi_write(REG_SEED,   32'd2);           // seed=2

        // Trigger
        axi_write(REG_CONTROL, 32'h00000001); // bit0 = start

        // Check busy
        repeat (3) @(posedge aclk);
        axi_read(REG_STATUS, status);
        check_str("STATUS busy=1 after start", status[1] === 1'b1, $sformatf("STATUS=0x%08X", status));

        // Wait for done
        wait_status_done(100000);

        axi_read(REG_STATUS, status);
        check_str("STATUS done=1", status[2] === 1'b1, $sformatf("STATUS=0x%08X", status));

        // Read output length
        begin
            integer out_len;
            out_len = (status >> 16) & 8'hFF;
            check_str("Output length = 5", out_len === 5, $sformatf("got %0d", out_len));

            // Read output tokens
            begin
                reg [7:0] tokens [0:15];
                reg [31:0] tok_word;
                for (i = 0; i < out_len && i < 16; i = i + 1) begin
                    axi_read(REG_OUTPUT + i*4, tok_word);
                    tokens[i] = tok_word[7:0];
                end

                $display("  Tokens: %0d %0d %0d %0d %0d",
                         tokens[0], tokens[1], tokens[2], tokens[3], tokens[4]);

                check_str("Token[0]=10", tokens[0] === 8'd10, $sformatf("got %0d", tokens[0]));
                check_str("Token[1]=4",  tokens[1] === 8'd4,  $sformatf("got %0d", tokens[1]));
                check_str("Token[2]=11", tokens[2] === 8'd11, $sformatf("got %0d", tokens[2]));
                check_str("Token[3]=24", tokens[3] === 8'd24, $sformatf("got %0d", tokens[3]));
                check_str("Token[4]=13", tokens[4] === 8'd13, $sformatf("got %0d", tokens[4]));
            end

            // Read perf cycles
            axi_read(REG_PERF, rdata);
            check_str("Perf cycles > 0", rdata > 0, $sformatf("got %0d", rdata));
        end

        // ================================================================
        // Test 5: max_gen Validation (stale value bug)
        // ================================================================
        test_num = 5;
        $display("\n=== Test %0d: max_gen Validation ===", test_num);

        // Clear first
        axi_write(REG_CONTROL, 32'h00000002);
        repeat (5) @(posedge aclk);

        // Write max_gen=0 (should trigger error)
        axi_write(REG_CONFIG, 32'h0080_00_00); // max_gen=0
        axi_write(REG_SEED,   32'd1);
        axi_write(REG_CONTROL, 32'h00000001); // start
        repeat (10) @(posedge aclk);
        axi_read(REG_STATUS, status);
        check_str("max_gen=0 triggers error", status[3] === 1'b1, $sformatf("STATUS=0x%08X", status));

        // Clear and try max_gen=16 (should trigger error)
        axi_write(REG_CONTROL, 32'h00000002);
        repeat (5) @(posedge aclk);
        axi_write(REG_CONFIG, 32'h0080_10_00); // max_gen=16
        axi_write(REG_SEED,   32'd1);
        axi_write(REG_CONTROL, 32'h00000001); // start
        repeat (10) @(posedge aclk);
        axi_read(REG_STATUS, status);
        check_str("max_gen=16 triggers error", status[3] === 1'b1, $sformatf("STATUS=0x%08X", status));

        // ================================================================
        // Test 6: SLVERR on Unmapped Address
        // ================================================================
        test_num = 6;
        $display("\n=== Test %0d: SLVERR on Unmapped Address ===", test_num);

        axi_read(32'hA000_0200, rdata); // unmapped
        check_str("RRESP=SLVERR for unmapped read", s_axi_rresp === 2'b10, $sformatf("RRESP=%0d", s_axi_rresp));

        // ================================================================
        // Test 7: Second Run (deterministic after clear)
        // ================================================================
        test_num = 7;
        $display("\n=== Test %0d: Second Run After Clear ===", test_num);

        axi_write(REG_CONTROL, 32'h00000002); // clear
        repeat (5) @(posedge aclk);
        axi_write(REG_CONFIG, 32'h0080_0F_00);
        axi_write(REG_SEED,   32'd2);
        axi_write(REG_CONTROL, 32'h00000001); // start

        wait_status_done(100000);
        axi_read(REG_STATUS, status);
        check_str("Second run done", status[2] === 1'b1, $sformatf("STATUS=0x%08X", status));

        begin
            reg [31:0] tok_word;
            integer out_len;
            out_len = (status >> 16) & 8'hFF;
            axi_read(REG_OUTPUT, tok_word);
            check_str("Second run Token[0]=10 (deterministic)", tok_word[7:0] === 8'd10,
                  $sformatf("got %0d", tok_word[7:0]));
        end

        // ================================================================
        // Summary
        // ================================================================
        $display("\n========================================");
        if (errors === 0)
            $display("ALL TESTS PASSED (%0d tests)", test_num);
        else
            $display("FAIL: %0d errors in %0d tests", errors, test_num);
        $display("========================================\n");

        $finish;
    end

    // Timeout watchdog
    initial begin
        #500_000_000; // 500ms at 1ns timescale
        $display("ERROR: Global timeout!");
        $finish;
    end

endmodule
