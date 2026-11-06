module pc (
    input logic clk,
    input logic reset,
    input logic pc_write_en,
    input logic [7:0] pc_next,
    input logic [7:0] loop_reg,
    input logic [7:0] branch_reg,

    output  logic [7:0] pc
);
    always_ff @(posedge clk) begin
        if (reset) begin
            pc <= 8'd0;
        end else if (pc_write_en) begin
            pc <= pc_next;
        end
    end

    always_comb begin
        unique case (pc_src)
            00 : pc_next = pc + 8'd1;
            01 : pc_next = branch_reg;
            10 : pc_next = loop_reg;
            default : pc_next = pc; 
        endcase
    end

endmodule
