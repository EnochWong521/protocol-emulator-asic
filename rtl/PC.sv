module program_counter (
    input   logic       clk,
    input   logic       reset,
    input   logic       PC_update,

    output  logic [7:0] PC
);
    always_ff @(posedge clk) begin
        if (reset == 1)
            PC <= 8'b00000000;
        else if (PC_update == 1)
            PC <= PC + 1;
    end

endmodule