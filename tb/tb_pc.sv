`timescale 1ns/1ps

// Run from the repository root:
// iverilog -g2012 -s tb_pc -o /tmp/tb_pc.vvp rtl/isa_pkg.sv rtl/pc.sv tb/tb_pc.sv
// vvp /tmp/tb_pc.vvp
module tb_pc;
    import isa_pkg::*;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [1:0] pc_sel = PC_HOLD;
    wire [PC_WIDTH-1:0] pc;
    int checked_steps = 0;

    always #5 clk = ~clk;
    pc dut (.clk(clk), .reset(reset), .pc_sel(pc_sel), .pc(pc));

    task automatic step(input logic [1:0] selection,
                        input logic [PC_WIDTH-1:0] expected_pc);
        logic [PC_WIDTH-1:0] previous_pc;
        @(negedge clk);
        previous_pc = pc;
        pc_sel = selection;
        #1;
        if (pc !== previous_pc)
            $fatal(1, "PC changed before rising edge");
        @(posedge clk); #1;
        if (pc !== expected_pc)
            $fatal(1, "PC=%h expected=%h selector=%b", pc, expected_pc, selection);
        checked_steps++;
    endtask

    initial begin
        @(posedge clk); #1;
        if (pc !== 0) $fatal(1, "initial reset failed");
        @(negedge clk);
        reset = 1'b0;

        // Visit every byte address and wrap FF + 1 to 00.
        for (int i = 1; i <= 256; i++)
            step(PC_PLUS_1, PC_WIDTH'(i));
        step(PC_HOLD, 8'h00);

        // Check both parities, including FE + 2 = 00 and FF + 2 = 01.
        for (int i = 1; i <= 128; i++)
            step(PC_PLUS_2, PC_WIDTH'(2*i));
        step(PC_PLUS_1, 8'h01);
        for (int i = 1; i <= 128; i++)
            step(PC_PLUS_2, PC_WIDTH'(1 + 2*i));
        step(PC_HOLD, 8'h01);
        step(2'b11, 8'h01); // Reserved future-target selector must hold.

        // Synchronous reset has priority over an increment selection.
        @(negedge clk);
        pc_sel = PC_PLUS_2;
        reset = 1'b1;
        #1;
        if (pc !== 8'h01) $fatal(1, "reset was asynchronous");
        @(posedge clk); #1;
        if (pc !== 0) $fatal(1, "reset did not win over increment");
        @(negedge clk);
        pc_sel = PC_HOLD;
        reset = 1'b0;
        step(PC_HOLD, 8'h00);
        step(PC_PLUS_2, 8'h02);

        $display("PASS: %0d PC selector checks, wraparound, hold, and synchronous reset", checked_steps);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "PC test timeout");
    end
endmodule
