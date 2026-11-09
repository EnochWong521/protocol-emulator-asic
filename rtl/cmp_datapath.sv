module cmp_datapath (
    input  logic       clk,
    input  logic       rst,
    input  logic       exec_cmp_imm,
    input  logic       exec_cmp_reg,
    input  logic       reg_sel,
    input  logic [1:0] cmp_op,
    input  logic [7:0] imm_data,
    input  logic [7:0] r0_data,
    input  logic [7:0] r1_data,
    output logic       cmp_flag
);
    import isa_pkg::*;

    logic [REG_WIDTH-1:0] operand_a, operand_b, other_reg;
    logic comparison_result;
    logic cmp_op_valid;

    // Operand vectors are unsigned, including for LT and GT.
    assign operand_a = reg_sel ? r1_data : r0_data;
    assign other_reg = reg_sel ? r0_data : r1_data;
    assign operand_b = exec_cmp_imm ? imm_data : other_reg;

    always_comb begin
        comparison_result = 1'b0;
        cmp_op_valid = 1'b1;

        case (cmp_op)
            CMP_EQ: comparison_result = (operand_a == operand_b);
            CMP_LT: comparison_result = (operand_a <  operand_b);
            CMP_GT: comparison_result = (operand_a >  operand_b);
            default: cmp_op_valid = 1'b0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst)
            cmp_flag <= 1'b0;
        // Exactly one valid CMP command may update the architectural flag.
        else if ((exec_cmp_imm ^ exec_cmp_reg) && cmp_op_valid)
            cmp_flag <= comparison_result;
    end
endmodule
