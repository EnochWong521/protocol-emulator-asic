`timescale 1ns/1ps

// Execute the checked-in pin pulse image through the complete core.
module tb_protocol_core;
    localparam int PULSE_COUNT = 10;
    localparam int FIRST_HIGH_EDGE = 14;
    int high_clocks = 8, low_clocks = 8, period_clocks, program_done_edge;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [7:0] memory [0:255];
    wire [7:0] inst_addr;
    wire [7:0] inst = memory[inst_addr];
    wire [3:0] gpio_out_value, gpio_out_enable;
    wire timing_overrun;
    string program_file = "examples/pin_pulse.hex";
    int high_edge = 0, low_edge = 0;
    int rising_edges = 0, falling_edges = 0;
    logic previous_pin = 1'b0;

    always #5 clk = ~clk;

    protocol_core dut (
        .clk(clk), .reset(reset), .inst(inst), .inst_addr(inst_addr),
        .gpio_in_async(4'b0000), .gpio_out_value(gpio_out_value),
        .gpio_out_enable(gpio_out_enable), .timing_overrun(timing_overrun)
    );

    initial begin
        if ($test$plusargs("half_low")) begin
            program_file = "examples/pin_pulse_half.hex";
            high_clocks = 16;
        end
        if ($value$plusargs("program=%s", program_file)) begin end
        period_clocks = high_clocks + low_clocks;
        program_done_edge = FIRST_HIGH_EDGE + 9 * period_clocks + high_clocks + 3;
        for (int i = 0; i < 256; i++) memory[i] = 8'hFF;
        $readmemh(program_file, memory, 0, 9);
        if ($test$plusargs("vcd")) begin
            $dumpfile("protocol_core.vcd");
            $dumpvars(0, tb_protocol_core);
        end

        repeat (2) @(posedge clk);
        #1;
        if (inst_addr !== 0 || gpio_out_value !== 0 || gpio_out_enable !== 0)
            $fatal(1, "reset must start at address zero with GPIO released");
        @(negedge clk);
        reset = 1'b0;

        for (int cycle = 1; cycle <= program_done_edge + 12; cycle++) begin
            @(posedge clk); #1;
            // WAIT immediately precedes each output; equal two-clock offsets cancel.
            if (timing_overrun !== 0)
                $fatal(1, "example missed a WAIT deadline at edge %0d", cycle);
            if (gpio_out_value !== ((cycle >= FIRST_HIGH_EDGE &&
                    cycle < FIRST_HIGH_EDGE + PULSE_COUNT * period_clocks &&
                    (cycle - FIRST_HIGH_EDGE) % period_clocks < high_clocks)
                    ? 4'b0001 : 4'b0000))
                $fatal(1, "unexpected pin value on active edge %0d: %b", cycle, gpio_out_value);
            if (gpio_out_enable !== ((cycle >= FIRST_HIGH_EDGE) ? 4'b0001 : 4'b0000))
                $fatal(1, "unexpected pin enable on active edge %0d: %b", cycle, gpio_out_enable);
            if (gpio_out_value[0] && !previous_pin) begin
                if (rising_edges > 0 && cycle - high_edge != period_clocks)
                    $fatal(1, "incorrect pulse period");
                if (rising_edges > 0 && cycle - low_edge != low_clocks)
                    $fatal(1, "incorrect low pulse width");
                high_edge = cycle;
                rising_edges++;
            end
            if (!gpio_out_value[0] && previous_pin) begin
                low_edge = cycle;
                falling_edges++;
                if (low_edge - high_edge != high_clocks)
                    $fatal(1, "incorrect high pulse width");
                $display("Pulse %0d: HIGH edge %0d, LOW edge %0d, width=%0d clocks",
                         falling_edges, high_edge, low_edge, low_edge - high_edge);
            end
            previous_pin = gpio_out_value[0];
            if (cycle >= program_done_edge &&
                (cycle - program_done_edge) % 3 == 0 && inst_addr !== 8'h08)
                $fatal(1, "JMP self failed at active edge %0d", cycle);
        end
        if (rising_edges != PULSE_COUNT || falling_edges != PULSE_COUNT)
            $fatal(1, "expected exactly 10 complete pulses, got %0d rising/%0d falling edges",
                   rising_edges, falling_edges);

        // The integrated core must release the driven pin on synchronous reset.
        @(negedge clk);
        reset = 1'b1;
        @(posedge clk); #1;
        if (inst_addr !== 0 || gpio_out_value !== 0 || gpio_out_enable !== 0)
            $fatal(1, "reset after execution did not release GPIO/restart fetch");

        $display("PASS: %0d pulses, HIGH=%0d clocks, LOW=%0d clocks; no overrun, LOOP 10, JMP self and reset",
                 falling_edges, high_clocks, low_clocks);
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "protocol core test timed out");
    end
endmodule
