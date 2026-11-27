`timescale 1ns/1ps

// Exercise unmodified protocol_core with an independent edge-driven SPI target.
// Default: 4 modes x 2 orders x 256 TX bytes x 3 MISO delays x 2 rates.
// Each RX byte is TX xor 0x96, so every RX byte is also covered in each setting.
// +vcd runs only the checked-in mode-0 example and writes spi.vcd.
// +too_fast is an expected failure: the loop cannot fit T=8 half-periods.
module tb_spi;
    logic clk = 0, reset = 1;
    logic [7:0] memory [0:255];
    wire [7:0] inst_addr;
    wire [7:0] inst = memory[inst_addr];
    wire [3:0] value, enable;
    wire overrun;
    tri [3:0] pins;
    wire sck = pins[0], mosi = pins[1], cs_n = pins[3];
    logic miso_drive = 0;
    for (genvar pin=0; pin<4; pin++) begin : pad_model
        assign pins[pin] = enable[pin] ? value[pin] : 1'bz;
    end
    assign pins[2] = !cs_n ? miso_drive : 1'bz;
    pullup (pins[3]);
    pulldown (pins[0]);
    pulldown (pins[1]);
    pulldown (pins[2]);

    int mode = 0, half_clocks = 64, delay_ns = 5;
    bit lsb_first = 0, active = 0, expect_overrun = 0;
    logic [7:0] tx_byte = 8'hA5, rx_byte = 8'h33, target_received;
    int samples = 0, clock_edges = 0, frames = 0, shifts_in = 0;
    int cases_run = 0, done_pc = 0;
    realtime last_clock_edge = 0, last_mosi_change = 0, last_sample = 0;
    string program_file = "examples/spi_mode0.hex";

    always #4 clk = ~clk; // Same 125 MHz system clock as PYNQ-Z2.
    protocol_core dut (
        .clk(clk), .reset(reset), .inst(inst), .inst_addr(inst_addr),
        .gpio_in_async(pins), .gpio_out_value(value),
        .gpio_out_enable(enable), .timing_overrun(overrun)
    );

    function automatic logic serial_bit(input logic [7:0] data, input int index);
        serial_bit = lsb_first ? data[index] : data[7-index];
    endfunction

    // Only external CS/SCLK edges drive the target; no CPU strobes are used.
    always @(negedge cs_n) begin
        if (!reset) begin
            if (sck !== mode[1]) $fatal(1, "SCLK not at CPOL on CS assertion");
            active = 1;
            samples = 0;
            clock_edges = 0;
            target_received = 0;
            last_clock_edge = 0;
            last_sample = 0;
            if (!mode[0]) miso_drive <= #(delay_ns) serial_bit(rx_byte, 0);
        end
    end

    always @(mosi) begin
        if (active && !reset && last_sample != 0 && $realtime-last_sample < 8.0)
            $fatal(1, "MOSI changed inside target's 8 ns hold requirement");
        last_mosi_change = $realtime;
    end

    always @(sck) begin
        if (active && !reset) begin
            if (sck !== 0 && sck !== 1) $fatal(1, "Unknown SCLK");
            if (clock_edges >= 16) $fatal(1, "More than eight SPI clocks");
            if (last_clock_edge != 0 && !expect_overrun &&
                $realtime-last_clock_edge != half_clocks*8.0)
                $fatal(1, "SPI mode %0d: half-period %0.3f ns, expected %0d ns",
                       mode, $realtime-last_clock_edge, half_clocks*8);
            last_clock_edge = $realtime;
            clock_edges++;
            // CPHA=0 samples leading edges; CPHA=1 samples trailing edges.
            if ((sck != mode[1]) != mode[0]) begin
                if (samples >= 8) $fatal(1, "More than eight samples");
                if ($realtime-last_mosi_change < 8.0)
                    $fatal(1, "MOSI setup shorter than target's 8 ns requirement");
                if (mosi !== serial_bit(tx_byte, samples))
                    $fatal(1, "Mode %0d order %0d TX %h bit %0d: MOSI=%b",
                           mode, lsb_first, tx_byte, samples, mosi);
                if (lsb_first) target_received = {mosi, target_received[7:1]};
                else target_received = {target_received[6:0], mosi};
                samples++;
                last_sample = $realtime;
            end else if (samples < 8) begin
                miso_drive <= #(delay_ns) serial_bit(rx_byte, samples);
            end
        end
    end

    always @(posedge cs_n) begin
        if (active) begin
            if (!reset) begin
                if (samples != 8 || clock_edges != 16 || target_received !== tx_byte)
                    $fatal(1, "Incomplete SPI frame: samples=%0d edges=%0d TX=%h expected=%h",
                           samples, clock_edges, target_received, tx_byte);
                if (sck !== mode[1]) $fatal(1, "SCLK not idle on CS deassertion");
                if ($realtime-last_clock_edge < half_clocks*8.0)
                    $fatal(1, "CS released before final clock hold completed");
                frames++;
            end
            active = 0;
        end
    end

    always @(posedge clk) begin
        if (!reset && dut.exec_shift_in) shifts_in++;
        #0.001;
        if (!reset && enable[2] !== 0) $fatal(1, "Controller drove MISO");
        if (!reset && !expect_overrun && overrun !== 0)
            $fatal(1, "SPI timing_overrun mode=%0d half_clocks=%0d", mode, half_clocks);
        if (!reset && active && clock_edges != 0 && enable !== 4'b1011)
            $fatal(1, "Incorrect SPI GPIO ownership: %b", enable);
    end

    task automatic emit(input logic [7:0] data, inout int p);
        memory[p] = data;
        p++;
    endtask

    task automatic make_program;
        int p, loop_pc;
        begin
            for (int i=0; i<256; i++) memory[i] = 8'hFF;
            p = 0;
            emit(8'hAD, p); // CS HIGH
            emit(mode[1] ? 8'hA1 : 8'hA0, p); // SCLK idle
            emit(8'hA4, p); // MOSI LOW
            emit(lsb_first ? 8'h38 : 8'h39, p); // Direction
            emit(8'hC0, p); emit(tx_byte, p);
            emit(8'hD0, p); emit(8'h5A, p); // Nonzero RX seed must be shifted out
            emit(8'(half_clocks >> 8), p); emit(8'(half_clocks), p);
            emit(8'h20, p); // Establish WAIT reference
            emit(8'hAC, p); // CS LOW
            loop_pc = p;
            emit(8'hA7, p); // MOSI shift
            emit(8'h20, p);
            emit(mode[1] ? 8'hA0 : 8'hA1, p); // Leading SCLK edge
            if (!mode[0]) emit(8'h98, p); // CPHA=0: receive after leading edge
            emit(8'h20, p);
            emit(mode[1] ? 8'hA1 : 8'hA0, p); // Trailing SCLK edge
            if (mode[0]) emit(8'h98, p); // CPHA=1: receive after trailing edge
            emit(8'h68, p); emit(8'(loop_pc), p);
            emit(8'h20, p);
            emit(8'hAD, p);
            done_pc = p;
            emit(8'h44, p); emit(8'(done_pc), p);
        end
    endtask

    task automatic start_case;
        begin
            @(negedge clk); reset = 1;
            repeat (3) @(negedge clk);
            if (enable !== 0 || inst_addr !== 0)
                $fatal(1, "Reset failed to release GPIO or clear PC");
            shifts_in = 0;
            frames = 0;
            @(negedge clk); reset = 0;
        end
    endtask

    task automatic finish_case;
        bit completed;
        begin
            completed = 0;
            for (int cycle=0; cycle<20*half_clocks+200 && !completed; cycle++) begin
                @(negedge clk);
                completed = frames == 1 && dut.pc_value == 8'(done_pc);
            end
            if (!completed) $fatal(1, "SPI frame timeout");
            if (dut.r1_data !== rx_byte || dut.r0_data !== 0 || shifts_in != 8)
                $fatal(1, "Mode %0d order %0d delay %0d TX %h: RX=%h expected=%h TXreg=%h shifts=%0d",
                       mode, lsb_first, delay_ns, tx_byte, dut.r1_data, rx_byte,
                       dut.r0_data, shifts_in);
            if (expect_overrun) begin
                if (overrun !== 1) $fatal(1, "Over-fast program did not report timing_overrun");
                $fatal(1, "EXPECTED FAILURE: T=%0d cannot fit this SPI loop; timing_overrun asserted",
                       half_clocks);
            end
            repeat (8) @(negedge clk);
            if (frames != 1 || cs_n !== 1 || sck !== mode[1] || dut.pc_value !== 8'(done_pc))
                $fatal(1, "Unexpected activity after SPI frame");
            cases_run++;
        end
    endtask

    initial begin
        if ($value$plusargs("spi_program=%s", program_file)) begin end
        if ($test$plusargs("vcd")) begin
            $dumpfile("spi.vcd");
            $dumpvars(0, tb_spi);
        end
        // First test the actual checked-in ROM, independently of the generator.
        for (int i=0; i<256; i++) memory[i] = 8'hFF;
        $readmemh(program_file, memory, 0, 23);
        done_pc = 22;
        start_case();
        finish_case();
        $display("PASS: checked-in mode-0 ROM, TX=A5 RX=33, 64 clocks/half (976.5625 kHz)");

        if (!$test$plusargs("vcd")) begin
            if ($test$plusargs("too_fast")) begin
                expect_overrun = 1;
                half_clocks = 8;
                make_program(); start_case(); finish_case();
            end
            for (int m=0; m<4; m++) begin
                mode = m;
                for (int order=0; order<2; order++) begin
                    lsb_first = order;
                    for (int rate=0; rate<2; rate++) begin
                        half_clocks = rate ? 16 : 64;
                        for (int d=0; d<3; d++) begin
                            case (d) 0: delay_ns=1; 1: delay_ns=5; 2: delay_ns=21; endcase
                            for (int b=0; b<256; b++) begin
                                tx_byte = 8'(b);
                                rx_byte = tx_byte ^ 8'h96;
                                // Change mode/program only with the core in reset.
                                @(negedge clk); reset = 1;
                                repeat (2) @(negedge clk);
                                make_program(); start_case(); finish_case();
                            end
                        end
                    end
                end
                $display("PASS: mode %0d, both orders, every TX/RX byte, 1/5/21 ns target delays, T=16/64", mode);
            end
            // Reset in a frame must release the bus; the next frame must recover.
            @(negedge clk); reset = 1;
            repeat (3) @(negedge clk);
            mode=0; lsb_first=0; half_clocks=64; delay_ns=5;
            tx_byte=8'hA5; rx_byte=8'h33;
            make_program(); start_case();
            wait (clock_edges == 5);
            @(negedge clk); reset=1;
            repeat (3) @(negedge clk);
            if (enable !== 0 || active || cs_n !== 1 || inst_addr !== 0)
                $fatal(1, "Mid-frame reset did not release/reinitialize SPI");
            start_case(); finish_case();
            $display("PASS: mid-frame reset and restart");
        end
        $display("PASS: %0d full-duplex SPI frames, pin ownership, edge timing, CS framing, no overrun", cases_run);
        $finish;
    end

    initial begin
        #200000000;
        $fatal(1, "SPI suite global timeout");
    end
endmodule
