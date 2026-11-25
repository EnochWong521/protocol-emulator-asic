module pynq_z2_top (
    input  wire       clk_125,
    input  wire       reset_sw,
    inout  wire [3:0] gpio
);
    (* ASYNC_REG = "TRUE" *) logic [1:0] reset_sync = 2'b11;
    wire core_reset = reset_sync[1];

    wire [7:0] inst_addr;
    wire [7:0] inst;
    wire [3:0] gpio_in_async;
    wire [3:0] gpio_out_value;
    wire [3:0] gpio_out_enable;
    wire       timing_overrun;

    always_ff @(posedge clk_125) begin
        reset_sync <= {reset_sync[0], reset_sw};
    end

    instruction_rom u_rom (
        .addr(inst_addr),
        .data(inst)
    );

    protocol_core u_core (
        .clk(clk_125),
        .reset(core_reset),
        .inst(inst),
        .inst_addr(inst_addr),
        .gpio_in_async(gpio_in_async),
        .gpio_out_value(gpio_out_value),
        .gpio_out_enable(gpio_out_enable),
        .timing_overrun(timing_overrun)
    );

    for (genvar pin = 0; pin < 4; pin++) begin : gen_gpio
        IOBUF u_iobuf (
            .I (gpio_out_value[pin]),
            .T (~gpio_out_enable[pin]),
            .O (gpio_in_async[pin]),
            .IO(gpio[pin])
        );
    end
endmodule
