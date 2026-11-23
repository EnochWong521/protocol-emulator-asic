`timescale 1ns/1ps

// Execute the checked-in pin pulse image through the complete core.
module tb_protocol_core;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [7:0] memory [0:255];
    wire [7:0] inst_addr;
    wire [7:0] inst = memory[inst_addr];
    wire [3:0] gpio_out_value, gpio_out_enable;
    string program_file = "examples/pin_pulse.hex";
    int high_edge = 0, low_edge = 0;

    always #5 clk = ~clk;

    protocol_core dut (
        .clk(clk), .reset(reset), .inst(inst), .inst_addr(inst_addr),
        .gpio_in_async(4'b0000), .gpio_out_value(gpio_out_value),
        .gpio_out_enable(gpio_out_enable)
    );

    initial begin
        if ($value$plusargs("program=%s", program_file)) begin end
        for (int i = 0; i < 256; i++) memory[i] = 8'hFF;
        $readmemh(program_file, memory, 0, 6);
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

        for (int cycle = 1; cycle <= 28; cycle++) begin
            @(posedge clk); #1;
            // WAIT_C: edges 1..3. HIGH: edges 4..5. WAIT: edges 6..14.
            // LOW: edges 15..16. JMP self: three edges per iteration thereafter.
            if (gpio_out_value !== ((cycle >= 5 && cycle < 16) ? 4'b0001 : 4'b0000))
                $fatal(1, "unexpected pin value on active edge %0d: %b", cycle, gpio_out_value);
            if (gpio_out_enable !== ((cycle >= 5) ? 4'b0001 : 4'b0000))
                $fatal(1, "unexpected pin enable on active edge %0d: %b", cycle, gpio_out_enable);
            if (cycle == 5) high_edge = cycle;
            if (cycle == 16) low_edge = cycle;
            if (cycle >= 16 && (cycle - 16) % 3 == 0 && inst_addr !== 8'h05)
                $fatal(1, "JMP self failed at active edge %0d", cycle);
        end
        if (low_edge - high_edge != 11)
            $fatal(1, "expected an 11-clock high pulse");

        // The integrated core must release the driven pin on synchronous reset.
        @(negedge clk);
        reset = 1'b1;
        @(posedge clk); #1;
        if (inst_addr !== 0 || gpio_out_value !== 0 || gpio_out_enable !== 0)
            $fatal(1, "reset after execution did not release GPIO/restart fetch");

        $display("PASS: pin pulse HIGH at edge %0d, LOW at edge %0d, width=%0d clocks; JMP self and reset",
                 high_edge, low_edge, low_edge - high_edge);
        $finish;
    end

    initial begin
        #2000;
        $fatal(1, "protocol core test timed out");
    end
endmodule
