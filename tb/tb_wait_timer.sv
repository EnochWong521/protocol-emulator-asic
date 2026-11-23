`timescale 1ns/1ps
// Elapsed-cycle compensation unit tests. Compile only unless simulation requested.
module tb_wait_timer;
    import isa_pkg::*;
    logic clk = 0, rst = 1, write_t = 0, start = 0, tick = 0;
    logic rebase = 0;
    logic [12:0] data = 20;
    logic [1:0] mode = WAIT_FULL;
    wire single_cycle, last_cycle, overrun;
    int cases = 0;
    always #5 clk = ~clk;
    wait_timer dut (
        .clk(clk), .rst(rst), .wait_c_write(write_t), .t_write_data(data),
        .wait_start(start), .wait_tick(tick), .wait_mode(mode),
        .wait_rebase(rebase),
        .wait_is_single_cycle(single_cycle), .wait_is_last_cycle(last_cycle),
        .timing_overrun(overrun)
    );
    task automatic step;
        @(posedge clk); #1; @(negedge clk);
    endtask
    task automatic configure(input int duration);
        write_t = 1; data = 13'(duration); step(); write_t = 0;
    endtask
    task automatic restart(input int duration);
        rst=1; start=0; tick=0; write_t=0; rebase=0; step(); rst=0;
        if (overrun !== 0 || dut.epoch_valid !== 0)
            $fatal(1, "reset did not clear timing state");
        configure(duration);
    endtask
    task automatic run_wait(input logic [1:0] selected, input int expected);
        int clocks;
        bit finish;
        mode=selected; start=1; clocks=0;
        do begin
            #1;
            finish = start ? single_cycle : last_cycle;
            step(); clocks++;
            start=0; tick=!finish;
            if (clocks > expected) $fatal(1, "WAIT exceeded expected execution time");
        end while (!finish);
        tick=0;
        if (clocks != expected || dut.elapsed_cycles !== 0 || dut.wait_remaining !== 0)
            $fatal(1, "incorrect completion/reset: clocks=%0d expected=%0d", clocks, expected);
        cases++;
    endtask
    initial begin
        @(negedge clk);
        restart(20);
        run_wait(WAIT_FULL,20); // First WAIT establishes the reference.
        repeat(3) step(); run_wait(WAIT_FULL,17);
        repeat(2) step(); run_wait(WAIT_HALF,8);
        repeat(2) step(); run_wait(WAIT_QUARTER,3);
        if (overrun !== 0) $fatal(1,"unexpected overrun");
        repeat(3) step(); configure(10); // Configuration edge also counts.
        run_wait(WAIT_FULL,6);
        restart(8); run_wait(WAIT_FULL,8);
        repeat(7) step(); run_wait(WAIT_FULL,1); // Exact boundary, not late.
        if (overrun !== 0) $fatal(1,"exact boundary flagged late");
        repeat(8) step(); run_wait(WAIT_FULL,1);
        if (overrun !== 1) $fatal(1,"late WAIT did not set overrun");
        run_wait(WAIT_FULL,8);
        if (overrun !== 1) $fatal(1,"overrun must remain sticky");
        restart(1); run_wait(WAIT_QUARTER,1);
        restart(2); run_wait(WAIT_FULL,2);
        restart(8191); run_wait(WAIT_FULL,8191);
        repeat(8190) step(); run_wait(WAIT_FULL,1);
        if (overrun !== 0) $fatal(1,"maximum exact interval flagged late");
        repeat(9000) step(); run_wait(WAIT_FULL,1);
        if (overrun !== 1) $fatal(1,"saturated elapsed counter hid overrun");
        restart(20); run_wait(WAIT_FULL,20);
        repeat(100) step(); rebase=1; step(); rebase=0;
        if(dut.elapsed_cycles!==0 || dut.epoch_valid!==1)
            $fatal(1,"WAIT_PIN did not reanchor elapsed timing");
        run_wait(WAIT_HALF,10);
        if(overrun!==0) $fatal(1,"reanchored wait incorrectly flagged late");
        restart(20);
        $display("PASS: %0d elapsed WAIT unit scenarios",cases);
        $finish;
    end
    initial begin #500000; $fatal(1,"timer test timeout"); end
endmodule
