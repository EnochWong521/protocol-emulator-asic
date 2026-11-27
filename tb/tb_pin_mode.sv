`timescale 1ns/1ps

// Real instruction fetch/control/datapath, with independently resolved pads.
module tb_pin_mode;
    logic clk=0, reset=1;
    logic [7:0] memory [0:255];
    wire [7:0] addr;
    wire [3:0] value, enable;
    wire overrun;
    tri1 [3:0] pins;
    logic [3:0] target_low=0;
    int mode_commits=0, checks=0, shift_bytes=0;
    protocol_core dut (
        .clk(clk), .reset(reset), .inst(memory[addr]), .inst_addr(addr),
        .gpio_in_async(pins), .gpio_out_value(value),
        .gpio_out_enable(enable), .timing_overrun(overrun)
    );
    for (genvar p=0; p<4; p++) begin : pads
        assign pins[p] = enable[p] ? value[p] : 1'bz;
        assign pins[p] = target_low[p] ? 1'b0 : 1'bz;
    end
    always #4 clk=~clk;
    always @(posedge clk) if (!reset && dut.exec_pin_mode) mode_commits++;

    task automatic restart;
        @(negedge clk); reset=1; target_low=0;
        repeat (3) @(negedge clk);
        for (int i=0; i<256; i++) memory[i]=8'hFF;
        if (enable !== 0 || dut.u_shift.open_drain_mask !== 0 || addr !== 0)
            $fatal(1, "PIN_MODE reset/default failure");
        mode_commits=0;
        reset=0;
    endtask

    // Called at a falling edge with the core ready to FETCH a new instruction.
    task automatic issue(input logic [7:0] op, input logic [7:0] operand=0,
                         input bit two_bytes=0);
        logic [7:0] start_pc;
        int cycles;
        begin
            if (dut.u_control.state !== dut.u_control.FETCH)
                $fatal(1, "Instruction driver is not at FETCH");
            start_pc=addr;
            memory[start_pc]=op;
            memory[8'(start_pc+1)]=operand;
            cycles=0;
            do begin
                @(posedge clk); #1; cycles++;
                if (cycles>200) $fatal(1, "Instruction %h did not retire", op);
            end while (dut.u_control.state != dut.u_control.FETCH);
            if (addr !== 8'(start_pc+(two_bytes ? 2 : 1)))
                $fatal(1, "Instruction %h advanced PC incorrectly", op);
            if (op==8'h56 && cycles!=3)
                $fatal(1, "PIN_MODE must take exactly three clocks");
            @(negedge clk);
        end
    endtask

    initial begin
        logic [3:0] expected_value, requests, expected_enable;
        logic [7:0] data, expected_reg;
        logic [12:0] elapsed_before;
        int previous_commits, p, loop_pc, end_pc;

        for (int mask=0; mask<16; mask++) begin
            restart();
            expected_value=4'hF; requests=4'hF;
            for (int pin=0; pin<4; pin++) issue(8'hA1 | (8'(pin)<<2));
            issue(8'hC0, 8'hA6, 1);
            issue(8'hD0, 8'h3C, 1);
            issue(8'hC4, 8'hA6, 1); // cmp_flag=1
            issue(8'h39); // LEFT
            issue(8'h00, 8'd64, 1);
            issue(8'h20);
            elapsed_before=dut.u_timer.elapsed_cycles;
            issue(8'h56, 8'(mask), 1);
            if (dut.r0_data !== 8'hA6 || dut.r1_data !== 8'h3C ||
                dut.cmp_flag !== 1 || dut.direction !== 1 ||
                dut.u_timer.t_reg !== 64 || dut.u_timer.epoch_valid !== 1 ||
                dut.u_timer.elapsed_cycles <= elapsed_before || overrun !== 0 ||
                value !== (4'hF ^ 4'(mask)) ||
                dut.u_shift.gpio_value_latch !== 4'hF ||
                enable !== (4'hF ^ 4'(mask)) || mode_commits!=1)
                $fatal(1, "PIN_MODE %h changed unrelated state or pad drive", mask);

            for (int pin=0; pin<4; pin++) begin
                for (int fixed_mode=0; fixed_mode<3; fixed_mode++) begin
                    issue(8'hA0 | (8'(pin)<<2) | 8'(fixed_mode));
                    if (fixed_mode<2) begin
                        expected_value[pin]=fixed_mode[0]; requests[pin]=1;
                    end else requests[pin]=0;
                    expected_enable=requests & ~(4'(mask) & expected_value);
                    if (value !== (expected_value & ~4'(mask)) || enable !== expected_enable)
                        $fatal(1, "Fixed output/release mismatch mask=%h pin=%0d mode=%0d",
                               mask, pin, fixed_mode);
                    checks++;
                end
            end

            // All pin/register/direction combinations: endpoint + exactly one shift.
            for (int dir=0; dir<2; dir++) begin
                issue(dir ? 8'h39 : 8'h38);
                for (int reg_num=0; reg_num<2; reg_num++) begin
                    for (int pin=0; pin<4; pin++) begin
                        // Each case is independent and remains inside the 256-byte image.
                        // Reset PC while retaining this test's expected configuration below.
                        restart();
                        issue(8'h56, 8'(mask), 1);
                        issue(dir ? 8'h39 : 8'h38);
                        issue(reg_num ? 8'hC0 : 8'hD0, 8'h3C, 1);
                        issue(reg_num ? 8'hD0 : 8'hC0, 8'hA6, 1);
                        data=8'hA6;
                        for (int bit_index=0; bit_index<8; bit_index++) begin
                            issue(8'hA3 | (8'(reg_num)<<4) | (8'(pin)<<2));
                            if (value[pin] !== (!mask[pin] && (dir ? data[7] : data[0])) ||
                                enable[pin] !== !(mask[pin] && (dir ? data[7] : data[0])))
                                $fatal(1, "Shift output mismatch mask=%h pin=%0d dir=%0d", mask, pin, dir);
                            data=dir ? data<<1 : data>>1;
                            expected_reg=reg_num ? dut.r1_data : dut.r0_data;
                            if (expected_reg !== data ||
                                (reg_num ? dut.r0_data : dut.r1_data) !== 8'h3C)
                                $fatal(1, "PIN_MODE affected shift/register selection");
                            checks++;
                        end
                        shift_bytes++;
                    end
                end
            end
        end

        // Switching modes must recompute pad enables without losing drive requests.
        restart();
        issue(8'hA1); issue(8'hA5); issue(8'hA9); issue(8'hAD);
        issue(8'h56, 8'h0F, 1);
        if (enable !== 0 || pins !== 4'hF) $fatal(1, "Open-drain HIGH did not release");
        target_low=4'hF;
        repeat (2) issue(8'h38); // Allow the input synchronizer to observe LOW.
        if (pins !== 0 || enable !== 0) $fatal(1, "Other device cannot pull released lines LOW");
        issue(8'h80); // SHIFT_IN reads actual externally held-low pad, not stored HIGH.
        if (dut.r0_data !== 0) $fatal(1, "SHIFT_IN bypassed pad readback");
        target_low=0;
        issue(8'hA2); // Explicit RELEASE P0.
        issue(8'h56, 8'h00, 1);
        if (enable !== 4'hE || value !== 4'hF)
            $fatal(1, "Mode replacement lost requests or re-enabled explicit RELEASE");

        // Reserved operands must stall without writes, including repeated EXECUTE clocks.
        for (int operand=16; operand<256; operand++) begin
            restart();
            issue(8'h56, 8'h05, 1);
            issue(8'hAD);
            p=addr; memory[p]=8'h56; memory[p+1]=8'(operand);
            previous_commits=mode_commits;
            repeat (8) @(negedge clk);
            if (addr !== 8'(p) || dut.u_shift.open_drain_mask !== 5 ||
                value !== 8 || enable !== 8 || mode_commits!=previous_commits ||
                dut.u_control.state !== dut.u_control.EXECUTE)
                $fatal(1, "Invalid PIN_MODE operand %h did not stall cleanly", operand);
        end
        restart(); memory[0]=8'h5E; memory[1]=0;
        repeat (8) @(negedge clk);
        if (addr !== 0 || mode_commits!=0 || enable !== 0)
            $fatal(1, "Reserved PIN_CTRL 5E became legal");

        // PIN_MODE inside a live hardware LOOP must not clear that loop.
        restart();
        p=0;
        memory[p++]=8'hC0; memory[p++]=8'hA6;
        memory[p++]=8'hD0; memory[p++]=8'h3C;
        memory[p++]=8'hC4; memory[p++]=8'hA6;
        memory[p++]=8'h39;
        loop_pc=p;
        memory[p++]=8'h56; memory[p++]=3;
        memory[p++]=8'h63; memory[p++]=8'(loop_pc);
        end_pc=p;
        repeat (40) @(negedge clk);
        if (addr !== 8'(end_pc) || mode_commits!=3 || dut.u_control.loop_active !== 0 ||
            dut.r0_data !== 8'hA6 || dut.r1_data !== 8'h3C ||
            dut.cmp_flag !== 1 || dut.direction !== 1)
            $fatal(1, "PIN_MODE did not preserve active loop/registers/flags");

        // Synchronous reset must suppress a pending mode write.
        restart(); memory[0]=8'h56; memory[1]=15;
        repeat (2) @(negedge clk); // Operand is fetched; EXECUTE is pending.
        reset=1;
        @(negedge clk);
        if (mode_commits!=0 || dut.u_shift.open_drain_mask !== 0 || enable !== 0)
            $fatal(1, "Reset did not suppress pending PIN_MODE");
        $display("PASS: PIN_MODE all 16 masks, %0d shifted bytes, %0d pad checks, 240 invalid operands, 5E reserved, state/loop retention and reset", shift_bytes, checks);
        $finish;
    end
    initial begin #2000000; $fatal(1, "PIN_MODE test timeout"); end
endmodule
