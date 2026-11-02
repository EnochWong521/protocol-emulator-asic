module pc (
    input logic clk,
    input logic reset,
    input logic pc_write_en,
    input logic [7:0] pc_next,

    output  logic [7:0] pc
);
    always_ff @(posedge clk) begin
        if (reset) begin
            pc <= 8'd0;
        end else if (pc_write_en) begin
            pc <= pc_next;
        end
    end

endmodule
