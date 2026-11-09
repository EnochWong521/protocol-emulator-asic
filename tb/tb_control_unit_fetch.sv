`timescale 1ns/1ps

// Steps 5-8: fetch addressing, lengths, completion updates, and timer commands.
// Run from the repository root:
// iverilog -g2012 -s tb_control_unit_fetch -o /tmp/tb_control_unit_fetch.vvp \
//   rtl/isa_pkg.sv rtl/pc.sv rtl/control_unit.sv tb/tb_control_unit_fetch.sv
// vvp /tmp/tb_control_unit_fetch.vvp
module tb_control_unit_fetch;
    import isa_pkg::*;

    // Independent length table indexed by the raw first byte; 1 means two bytes.
    // Each word covers the 32 encodings of one primary opcode, highest first.
    localparam logic [255:0] TWO_BYTE_ENCODINGS = {
        32'h00000000, // 111: DATA_IO
        32'h00FF00FF, // 110: MOVE immediate submodes, for either register
        32'h00000000, // 101: SHIFT_OUT
        32'h00000000, // 100: SHIFT_IN
        32'hFFFFFFFF, // 011: LOOP
        32'h55555555, // 010: PIN_CTRL branch mode (even first-byte values)
        32'h00000000, // 001: WAIT / SET_DIR
        32'hFFFFFFFF  // 000: WAIT_C
    };
    // Bits 0, 8, 16, 24, 25: WAIT FULL/HALF/QUARTER and SET_DIR RIGHT/LEFT.
    localparam logic [31:0] LEGAL_WAIT_ENCODINGS = 32'h03010101;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic wait_is_single_cycle = 1'b0;
    logic wait_is_last_cycle = 1'b0;
    wire [PC_WIDTH-1:0] pc, inst_addr;
    wire [INST_WIDTH-1:0] inst;
    wire [1:0] pc_sel;
    wire wait_start, wait_c_write, wait_tick, direction;
    wire [T_WIDTH-1:0] t_write_data;
    wire [1:0] wait_mode;
    logic [INST_WIDTH-1:0] memory [0:255];
    int checked_cycles = 0;
    int one_byte_cases = 0;
    int two_byte_cases = 0;

    always #5 clk = ~clk;
    assign inst = memory[inst_addr];

    pc u_pc (
        .clk(clk), .reset(reset), .pc_sel(pc_sel), .pc(pc)
    );

    control_unit dut (
        .clk(clk), .reset(reset), .inst(inst), .pc_value(pc),
        .inst_addr(inst_addr), .pc_sel(pc_sel),
        .wait_is_single_cycle(wait_is_single_cycle),
        .wait_is_last_cycle(wait_is_last_cycle),
        .wait_start(wait_start), .wait_c_write(wait_c_write),
        .t_write_data(t_write_data), .wait_mode(wait_mode), .wait_tick(wait_tick),
        .direction(direction)
    );

    task automatic reset_case(input logic [7:0] first_byte,
                              input logic [7:0] second_byte);
        @(negedge clk);
        reset = 1'b1;
        wait_is_single_cycle = 1'b0;
        wait_is_last_cycle = 1'b0;
        memory[0] = first_byte;
        memory[1] = second_byte;
        @(posedge clk); #1;
        if (pc !== 0 || dut.state !== dut.FETCH ||
            dut.ir !== 0 || dut.imm !== 0 || direction !== DIR_RIGHT)
            $fatal(1, "reset failed");
        if (pc_sel !== PC_HOLD ||
            {wait_start, wait_c_write, wait_tick} !== 3'b000)
            $fatal(1, "control strobe during reset");
        @(negedge clk);
        reset = 1'b0;
    endtask

    task automatic cycle(input logic [1:0] before_state,
                         input logic [1:0] after_state,
                         input logic [7:0] expected_addr,
                         input logic expected_start,
                         input logic [1:0] expected_sel = PC_HOLD,
                         input logic [7:0] expected_pc_after = 0,
                         input logic expected_write = 1'b0);
        logic [7:0] expected_ir, expected_imm;
        #1;
        if (dut.state !== before_state || inst_addr !== expected_addr)
            $fatal(1, "fetch state/address incorrect: state=%b addr=%h",
                   dut.state, inst_addr);
        if (pc !== 0 || pc_sel !== expected_sel || wait_start !== expected_start)
            $fatal(1, "PC selection or WAIT start incorrect");
        if (wait_c_write !== expected_write || wait_tick !== (before_state == dut.WAIT_REMAIN))
            $fatal(1, "timer write/tick command incorrect");
        expected_ir = (before_state == dut.FETCH) ? memory[expected_addr] : dut.ir;
        expected_imm = (before_state == dut.FETCH_OPERAND) ? memory[expected_addr] : dut.imm;
        @(posedge clk); #1;
        if (dut.state !== after_state || pc !== expected_pc_after)
            $fatal(1, "state transition or PC completion update incorrect");
        if (dut.ir !== expected_ir || dut.imm !== expected_imm)
            $fatal(1, "instruction capture/retention incorrect");
        checked_cycles++;
    endtask

    initial begin
        for (int i = 0; i < 256; i++)
            memory[i] = 8'hFF;

        // The second byte resembles SHIFT_OUT; it must be captured as data.
        reset_case(8'h01, 8'hA5);
        cycle(dut.FETCH, dut.FETCH_OPERAND, 8'd0, 0);
        cycle(dut.FETCH_OPERAND, dut.EXECUTE, 8'd1, 0);
        if (t_write_data !== 13'h01A5)
            $fatal(1, "full WAIT_C write data incorrect");
        cycle(dut.EXECUTE, dut.FETCH, 8'd0, 0, PC_PLUS_2, 8'd2, 1);
        if (dut.ir !== 8'h01 || dut.imm !== 8'hA5)
            $fatal(1, "WAIT_C did not capture adjacent bytes");

        // One-byte SET_DIR skips operand fetch and leaves IMM untouched.
        reset_case(8'h39, 8'hFF);
        cycle(dut.FETCH, dut.EXECUTE, 8'd0, 0);
        cycle(dut.EXECUTE, dut.FETCH, 8'd0, 0, PC_PLUS_1, 8'd1);
        if (direction !== DIR_LEFT || dut.imm !== 0)
            $fatal(1, "one-byte SET_DIR used an operand");

        // Single-cycle WAIT completes without fetching an operand.
        reset_case(8'h20, 8'hFF);
        wait_is_single_cycle = 1'b1;
        cycle(dut.FETCH, dut.EXECUTE, 8'd0, 0);
        cycle(dut.EXECUTE, dut.FETCH, 8'd0, 1, PC_PLUS_1, 8'd1);

        // A blocked WAIT retains PC and IR, and never restarts the timer.
        reset_case(8'h30, 8'hFF);
        cycle(dut.FETCH, dut.EXECUTE, 8'd0, 0);
        cycle(dut.EXECUTE, dut.WAIT_REMAIN, 8'd0, 1);
        cycle(dut.WAIT_REMAIN, dut.WAIT_REMAIN, 8'd0, 0);
        @(negedge clk);
        wait_is_last_cycle = 1'b1;
        cycle(dut.WAIT_REMAIN, dut.FETCH, 8'd0, 0, PC_PLUS_1, 8'd1);

        // WAIT_C zero must neither write the timer nor advance PC.
        reset_case(8'h00, 8'h00);
        cycle(dut.FETCH, dut.FETCH_OPERAND, 8'd0, 0);
        cycle(dut.FETCH_OPERAND, dut.EXECUTE, 8'd1, 0);
        cycle(dut.EXECUTE, dut.EXECUTE, 8'd0, 0);

        // Include reserved encodings: length must not depend on legality.
        for (int byte_value = 0; byte_value < 256; byte_value++) begin
            reset_case(INST_WIDTH'(byte_value), ~INST_WIDTH'(byte_value));
            if (TWO_BYTE_ENCODINGS[byte_value]) begin
                cycle(dut.FETCH, dut.FETCH_OPERAND, 8'd0, 0);
                cycle(dut.FETCH_OPERAND, dut.EXECUTE, 8'd1, 0);
                two_byte_cases++;
            end
            else begin
                cycle(dut.FETCH, dut.EXECUTE, 8'd0, 0);
                one_byte_cases++;
            end

            // Unsupported opcodes and reserved WAIT/SET_DIR encodings hold PC.
            if (byte_value >= 64 ||
                (byte_value >= 32 && byte_value < 64 &&
                 !LEGAL_WAIT_ENCODINGS[byte_value - 32]))
                cycle(dut.EXECUTE, dut.EXECUTE, 8'd0, 0);
        end

        if (one_byte_cases != 160 || two_byte_cases != 96)
            $fatal(1, "length coverage totals incorrect");
        $display("PASS: %0d one-byte and %0d two-byte encodings; %0d cycle checks",
                 one_byte_cases, two_byte_cases, checked_cycles);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "fetch test timeout");
    end
endmodule
