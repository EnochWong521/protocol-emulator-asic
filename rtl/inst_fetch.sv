module inst_fetch (
    input  logic       clk,
    input  logic       reset,
    input  logic [7:0] pc_value,
    input  logic [7:0] inst,
    input  logic       ir_load,
    input  logic       imm_load,

    output logic [7:0] inst_addr,
    output logic [7:0] ir,
    output logic [7:0] imm
);
    import isa_pkg::*;

    assign inst_addr = imm_load
                     ? pc_value + PC_WIDTH'(ONE_BYTE)
                     : pc_value;

    always_ff @(posedge clk) begin
        if (reset) begin
            ir <= '0;
            imm <= '0;
        end
        else begin
            if (ir_load)
                ir <= inst;

            if (imm_load)
                imm <= inst;
        end
    end
endmodule
