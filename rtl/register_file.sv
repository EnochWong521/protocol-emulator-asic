module register_file (
    input   logic         clk,
    input   logic         rst,
    input   logic         write_en,
    input   logic         write_sel,
    input   logic [7:0]   write_data,

    output  logic [7:0]   r0_data,
    output  logic [7:0]   r1_data
);

    always_ff @(posedge clk) begin
        if (rst == 1) begin
            r0_data <= '0;
            r1_data <= '0;
        end

        else if (write_en == 1) begin
            if (write_sel == 0) begin
                r0_data <= write_data;
            end
            else begin
                r1_data <= write_data;
            end
        end
    end

endmodule