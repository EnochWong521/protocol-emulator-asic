`timescale 1ns/1ps

// Complete firmware-driven UART TX frame; +payload=XX selects any byte.
module tb_uart_tx;
    localparam int BIT_CLOCKS = 868;
    logic [7:0] payload = 8'h55;
    localparam int IDLE_EDGE = BIT_CLOCKS + 11;
    localparam int START_EDGE = IDLE_EDGE + BIT_CLOCKS;
    localparam int FRAME_END_EDGE = START_EDGE + 10 * BIT_CLOCKS;

    logic clk = 0, reset = 1;
    logic [7:0] memory [0:255];
    wire [7:0] inst_addr;
    wire [7:0] inst = memory[inst_addr];
    wire [3:0] gpio_out_value, gpio_out_enable;
    wire timing_overrun;
    // External TX pad model: idle-high pull-up while the core releases P0.
    wire tx = gpio_out_enable[0] ? gpio_out_value[0] : 1'b1;
    string program_file = "examples/uart_tx_8n1.hex";
    int shifted_bits = 0;
    logic expected_tx, output_commit;
    logic [1:0] output_mode;

    always #5 clk = ~clk; // 100 MHz
    protocol_core dut (
        .clk(clk), .reset(reset), .inst(inst), .inst_addr(inst_addr),
        .gpio_in_async(4'b0000), .gpio_out_value(gpio_out_value),
        .gpio_out_enable(gpio_out_enable), .timing_overrun(timing_overrun)
    );

    initial begin
        if ($value$plusargs("uart_program=%s", program_file)) begin end
        for (int i = 0; i < 256; i++) memory[i] = 8'hFF;
        $readmemh(program_file, memory, 0, 18);
        if ($value$plusargs("payload=%h", payload)) memory[4] = payload;
        if ($test$plusargs("vcd")) begin
            $dumpfile("uart_tx.vcd");
            $dumpvars(0, tb_uart_tx);
        end
        repeat (2) @(posedge clk);
        #1;
        if (gpio_out_enable !== 0 || tx !== 1)
            $fatal(1, "UART pad must idle high while reset releases GPIO");
        @(negedge clk); reset = 0;

        for (int cycle = 1; cycle <= FRAME_END_EDGE + BIT_CLOCKS; cycle++) begin
            @(posedge clk);
            output_commit = dut.exec_shift_out;
            output_mode = dut.shift_out_mode;
            #1;
            expected_tx = 1;
            if (cycle >= START_EDGE && cycle < FRAME_END_EDGE) begin
                case ((cycle - START_EDGE) / BIT_CLOCKS)
                    0: expected_tx = 0;
                    9: expected_tx = 1;
                    default: expected_tx = payload[(cycle - START_EDGE) / BIT_CLOCKS - 1];
                endcase
            end
            if (tx !== expected_tx || timing_overrun !== 0)
                $fatal(1, "UART mismatch/overrun at active edge %0d: TX=%b expected=%b overrun=%b",
                       cycle, tx, expected_tx, timing_overrun);
            if (gpio_out_enable !== (cycle >= IDLE_EDGE ? 4'b0001 : 4'b0000) ||
                gpio_out_value[3:1] !== 0)
                $fatal(1, "UART program changed an unrelated pin or output enable");
            if (output_commit) begin
                if (cycle < IDLE_EDGE || cycle > FRAME_END_EDGE ||
                    (cycle - IDLE_EDGE) % BIT_CLOCKS != 0)
                    $fatal(1, "GPIO commit outside a UART bit boundary at edge %0d", cycle);
                if (output_mode == isa_pkg::SHIFT_OUT_SHIFT) begin
                    if (cycle != START_EDGE + (shifted_bits + 1) * BIT_CLOCKS)
                        $fatal(1, "data-bit commit did not occur on its scheduled edge");
                    $display("Data bit %0d = %b at active edge %0d", shifted_bits, tx, cycle);
                    shifted_bits++;
                end
            end
            if (cycle >= FRAME_END_EDGE && (cycle - FRAME_END_EDGE) % 3 == 0 &&
                dut.pc_value !== 8'h11)
                $fatal(1, "UART program did not finish in its idle self-jump");
        end
        if (shifted_bits != 8 || dut.r0_data !== 0)
            $fatal(1, "expected exactly eight shifts and an exhausted TX register");
        $display("PASS: UART TX 0x%02h, 8N1, %0d clocks/bit; start, data, stop, idle and no overrun", payload, BIT_CLOCKS);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "UART TX test timeout");
    end
endmodule
