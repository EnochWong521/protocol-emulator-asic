module shift_datapath (
    input  logic       clk,
    input  logic       rst,
    input  logic       exec_shift_in,
    input  logic       exec_shift_out,
    input  logic       reg_sel,          // 0 selects R0; 1 selects R1
    input  logic [1:0] pin_sel,          
    input  logic [1:0] shift_out_mode,   // 00 LOW, 01 HIGH, 10 RELEASE, 11 SHIFT
    input  logic       shift_dir,        // 0 shifts RIGHT; 1 shifts LEFT
    input  logic [3:0] gpio_in_async,
    output logic [3:0] gpio_in_sync,
    output logic [3:0] gpio_out_value,
    output logic [3:0] gpio_out_enable,
    output logic [7:0] r0_data,
    output logic [7:0] r1_data
);

    logic [3:0] gpio_sync1;
    logic [7:0] selected_reg;
    logic       write_en;
    logic [7:0] write_data;


    register_file registers (
        .clk        (clk),
        .rst        (rst),
        .write_en   (write_en),
        .write_sel  (reg_sel),
        .write_data (write_data),
        .r0_data    (r0_data),
        .r1_data    (r1_data)
    );

    // Needed because shift in needs this before execution
    always_ff @(posedge clk) begin
        if (rst) begin
            gpio_sync1  <= 4'b0000;
            gpio_in_sync <= 4'b0000;
        end
        else begin
            gpio_sync1   <= gpio_in_async;
            gpio_in_sync <= gpio_sync1;
        end
    end

    // Read register calculate its next value
    // The register file saves this value on the execute rising edge.
    always_comb begin
        if (reg_sel == 1'b0) begin
            selected_reg = r0_data;
        end
        else begin
            selected_reg = r1_data;
        end

        write_en = 1'b0;
        write_data = selected_reg;

        if (exec_shift_in) begin
            write_en = 1'b1;
            if (shift_dir == 1'b0) begin
                write_data = {gpio_in_sync[pin_sel], selected_reg[7:1]};
            end
            else begin
                write_data = {selected_reg[6:0], gpio_in_sync[pin_sel]};
            end
        end
        else if (exec_shift_out && shift_out_mode == 2'b11) begin
            write_en = 1'b1;
            if (shift_dir == 1'b0) begin
                write_data = {1'b0, selected_reg[7:1]};
            end
            else begin
                write_data = {selected_reg[6:0], 1'b0};
            end
        end
    end


    always_ff @(posedge clk) begin
        if (rst) begin
            gpio_out_value  <= 4'b0000;
            gpio_out_enable <= 4'b0000;
        end
        else if (exec_shift_out) begin
            case (shift_out_mode)
                2'b00: begin
                    gpio_out_value[pin_sel]  <= 1'b0;
                    gpio_out_enable[pin_sel] <= 1'b1;
                end
                2'b01: begin
                    gpio_out_value[pin_sel]  <= 1'b1;
                    gpio_out_enable[pin_sel] <= 1'b1;
                end
                2'b10: begin
                    // Retain the stored output value while releasing the pin.
                    gpio_out_enable[pin_sel] <= 1'b0;
                end
                2'b11: begin
                    gpio_out_enable[pin_sel] <= 1'b1;
                    if (shift_dir == 1'b0) begin
                        gpio_out_value[pin_sel] <= selected_reg[0];
                    end
                    else begin
                        gpio_out_value[pin_sel] <= selected_reg[7];
                    end
                end
            endcase
        end
    end

endmodule
