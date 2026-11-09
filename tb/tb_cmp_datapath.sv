`timescale 1ns/1ps

// Run from the repository root:
// iverilog -g2012 -s tb_cmp_datapath -o /tmp/tb_cmp_datapath.vvp \
//   rtl/isa_pkg.sv rtl/cmp_datapath.sv tb/tb_cmp_datapath.sv
// vvp /tmp/tb_cmp_datapath.vvp
// Add +vcd to the vvp command to write cmp_datapath.vcd in the current directory.
module tb_cmp_datapath;
    import isa_pkg::*;

    // Ascending unsigned values, indexed from the least significant byte.
    localparam logic [6*REG_WIDTH-1:0] BOUNDARY_VALUES = {
        8'd255, 8'd254, 8'd128, 8'd127, 8'd1, 8'd0
    };

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic exec_cmp_imm = 1'b0;
    logic exec_cmp_reg = 1'b0;
    logic reg_sel = REG_R0;
    logic [1:0] cmp_op = CMP_EQ;
    logic [REG_WIDTH-1:0] imm_data = '0;
    logic [REG_WIDTH-1:0] r0_data = '0;
    logic [REG_WIDTH-1:0] r1_data = '0;
    wire cmp_flag;
    int comparison_cases = 0;
    int suppression_cases = 0;
    int checked_cycles = 0;

    always #5 clk = ~clk;

    cmp_datapath dut (
        .clk(clk), .rst(rst),
        .exec_cmp_imm(exec_cmp_imm), .exec_cmp_reg(exec_cmp_reg),
        .reg_sel(reg_sel), .cmp_op(cmp_op), .imm_data(imm_data),
        .r0_data(r0_data), .r1_data(r1_data), .cmp_flag(cmp_flag)
    );

    task automatic step(input logic reset_value,
                        input logic imm_exec,
                        input logic reg_exec,
                        input logic selected_reg,
                        input logic [1:0] operation,
                        input logic [REG_WIDTH-1:0] r0,
                        input logic [REG_WIDTH-1:0] r1,
                        input logic [REG_WIDTH-1:0] immediate,
                        input logic expected_flag);
        logic previous_flag;
        @(negedge clk);
        previous_flag = cmp_flag;
        rst = reset_value;
        exec_cmp_imm = imm_exec;
        exec_cmp_reg = reg_exec;
        reg_sel = selected_reg;
        cmp_op = operation;
        r0_data = r0;
        r1_data = r1;
        imm_data = immediate;
        #1;
        if (cmp_flag !== previous_flag)
            $fatal(1, "flag changed before rising edge, including synchronous reset");
        @(posedge clk); #1;
        if (cmp_flag !== expected_flag)
            $fatal(1, "flag=%b expected=%b rst=%b IMM/REG=%b%b reg=%b op=%b R0=%h R1=%h IMM=%h",
                   cmp_flag, expected_flag, rst, exec_cmp_imm, exec_cmp_reg,
                   reg_sel, cmp_op, r0_data, r1_data, imm_data);
        checked_cycles++;
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("cmp_datapath.vcd");
            $dumpvars(0, tb_cmp_datapath);
        end
    end

    initial begin
        logic [REG_WIDTH-1:0] a, b, other, immediate;
        logic expected_flag;

        @(posedge clk); #1;
        if (cmp_flag !== 1'b0)
            $fatal(1, "initial reset did not clear flag");
        checked_cycles++;

        // Reference ordering uses the ascending table indices, independently
        // of the DUT operand muxes and the eight-bit values it compares.
        for (int ai = 0; ai < 6; ai++) begin
            for (int bi = 0; bi < 6; bi++) begin
                a = BOUNDARY_VALUES[ai*REG_WIDTH +: REG_WIDTH];
                b = BOUNDARY_VALUES[bi*REG_WIDTH +: REG_WIDTH];
                for (int selected = 0; selected < 2; selected++) begin
                    for (int source = 0; source < 2; source++) begin
                        // An unused operand source differs from B to expose
                        // accidental use of the other register or stale IMM.
                        other = (source == 0) ? ~b : b;
                        immediate = (source == 0) ? b : ~b;
                        for (int operation = 0; operation < 3; operation++) begin
                            case (operation[1:0])
                                CMP_EQ: expected_flag = (ai == bi);
                                CMP_LT: expected_flag = (ai < bi);
                                CMP_GT: expected_flag = (ai > bi);
                                default: $fatal(1, "invalid test operation");
                            endcase
                            step(0, source == 0, source == 1, selected[0], operation[1:0],
                                 selected[0] ? other : a, selected[0] ? a : other,
                                 immediate, expected_flag);
                            comparison_cases++;
                        end
                    end
                end
            end
        end

        // Exercise every inactive/invalid strobe-and-operation combination
        // from both stored flag values. Non-CMP instructions supply no strobes.
        for (int stored = 0; stored < 2; stored++) begin
            step(0, 1, 0, REG_R0, CMP_EQ, 8'hA5, 8'h00,
                 stored[0] ? 8'hA5 : 8'h5A, stored[0]);
            for (int strobes = 0; strobes < 4; strobes++) begin
                for (int operation = 0; operation < 4; operation++) begin
                    if (strobes == 0 || strobes == 3 || operation[1:0] == CMP_RESERVED) begin
                        // Valid operations would produce the opposite flag
                        // if a disabled/conflicting command leaked through.
                        case (operation[1:0])
                            CMP_EQ: b = stored[0] ? 8'd0 : 8'd1;
                            CMP_LT: b = stored[0] ? 8'd0 : 8'd2;
                            CMP_GT: b = stored[0] ? 8'd2 : 8'd0;
                            default: b = 8'd255;
                        endcase
                        step(0, strobes[1], strobes[0], stored[0], operation[1:0],
                             stored[0] ? b : 8'd1, stored[0] ? 8'd1 : b, b, stored[0]);
                        suppression_cases++;
                    end
                end
            end
        end

        // Flag is currently one. Reset must act only on the rising edge and
        // override a valid comparison that would otherwise keep it one.
        step(1, 1, 0, REG_R0, CMP_EQ, 8'hA5, 8'h00, 8'hA5, 0);
        step(1, 0, 1, REG_R1, CMP_EQ, 8'h3C, 8'h3C, 8'hFF, 0);
        step(0, 0, 0, REG_R0, CMP_EQ, 8'h00, 8'hFF, 8'h00, 0);
        // Reset release restores normal operation without another state.
        step(0, 0, 1, REG_R1, CMP_GT, 8'h01, 8'hFF, 8'h00, 1);

        if (comparison_cases != 432 || suppression_cases != 20)
            $fatal(1, "comparison/retention coverage incomplete");
        $display("PASS: %0d unsigned comparisons, %0d retention/invalid-command cases",
                 comparison_cases, suppression_cases);
        $display("PASS: synchronous reset priority and flag edge timing; %0d cycle checks",
                 checked_cycles);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "comparison test timeout");
    end
endmodule
