`timescale 1ns/1ps

// iverilog -g2012 -s tb_register_file -o /tmp/tb_register_file.vvp \
//   rtl/isa_pkg.sv rtl/register_file.sv tb/tb_register_file.sv
// vvp /tmp/tb_register_file.vvp [+vcd]
module tb_register_file;
    import isa_pkg::*;
    localparam logic [39:0] VALUES = {8'hFF, 8'hA5, 8'h80, 8'h01, 8'h00};
    logic clk = 0;
    logic rst = 1;
    logic write_en = 0;
    logic write_sel = REG_R0;
    logic [7:0] write_data = 0;
    wire [7:0] r0_data, r1_data;
    int checked_cycles = 0;

    always #5 clk = ~clk;
    register_file dut (.*);

    task automatic step(input logic enable, selection,
                        input logic [7:0] data, expected_r0, expected_r1,
                        input logic reset_value = 0);
        logic [15:0] previous_data;
        @(negedge clk);
        previous_data = {r0_data, r1_data};
        rst = reset_value;
        write_en = enable;
        write_sel = selection;
        write_data = data;
        #1;
        if ({r0_data, r1_data} !== previous_data)
            $fatal(1, "register changed before rising edge");
        @(posedge clk); #1;
        if ({r0_data, r1_data} !== {expected_r0, expected_r1})
            $fatal(1, "R0=%h R1=%h expected=%h/%h", r0_data, r1_data,
                   expected_r0, expected_r1);
        checked_cycles++;
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("register_file.vcd");
            $dumpvars(0, tb_register_file);
        end
    end

    initial begin
        logic [7:0] value, expected_r1;
        @(posedge clk); #1;
        if ({r0_data, r1_data} !== 16'h0000)
            $fatal(1, "initial reset failed");
        checked_cycles++;
        step(1, REG_R0, 8'hAA, 8'hAA, 0);
        step(1, REG_R1, 8'h55, 8'hAA, 8'h55);
        expected_r1 = 8'h55;
        for (int i = 0; i < 5; i++) begin
            value = VALUES[i*8 +: 8];
            step(1, REG_R0, value, value, expected_r1);
            step(0, REG_R1, ~value, value, expected_r1);
            expected_r1 = ~value;
            step(1, REG_R1, expected_r1, value, expected_r1);
            step(0, REG_R0, ~value, value, expected_r1);
        end
        step(1, REG_R0, 8'hFF, 8'hFF, expected_r1);
        step(1, REG_R1, 8'hA5, 8'hFF, 8'hA5);
        // Reset clears both registers and overrides either selected write.
        step(1, REG_R0, 8'hFF, 0, 0, 1);
        step(1, REG_R1, 8'hFF, 0, 0, 1);
        step(0, REG_R1, 8'hFF, 0, 0);
        step(1, REG_R1, 8'h80, 0, 8'h80);
        $display("PASS: register reset, selected writes, retention and edge timing; %0d checks",
                 checked_cycles);
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "register test timeout");
    end
endmodule
