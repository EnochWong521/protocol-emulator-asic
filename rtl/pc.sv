module pc (
    input logic clk,
    input logic reset,
    input logic [1:0] pc_sel,
    input logic [7:0] pc_target, // Connect directly to inst_fetch.imm.

    output  logic [7:0] pc
);
    import isa_pkg::*;

    always_ff @(posedge clk) begin
        if (reset) begin
            pc <= '0;
        end else begin
            case (pc_sel)
                PC_PLUS_1: pc <= pc + PC_WIDTH'(ONE_BYTE);
                PC_PLUS_2: pc <= pc + PC_WIDTH'(TWO_BYTES);
                PC_TARGET: pc <= pc_target;
                default:   ; // Hold.
            endcase
        end
    end

endmodule
