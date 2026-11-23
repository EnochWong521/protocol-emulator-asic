`timescale 1ns/1ps
// Integration: full-width WAIT_C, zero rejection, compensation and missed intervals.
module tb_control_unit;
    logic clk=0, reset=1;
    logic [7:0] memory [0:255];
    wire [7:0] addr;
    wire [7:0] inst=memory[addr];
    wire overrun;
    int edges=0;
    always #5 clk=~clk;
    protocol_core dut(.clk(clk),.reset(reset),.inst(inst),.inst_addr(addr),
        .gpio_in_async(4'b0),.gpio_out_value(),.gpio_out_enable(),.timing_overrun(overrun));
    task automatic step;
        @(posedge clk); #1; edges++;
    endtask
    task automatic retire(input int clocks,input logic [7:0] pc);
        for(int i=0;i<clocks;i++) begin
            step();
            if (i<clocks-1 && dut.u_control.state==dut.u_control.FETCH)
                $fatal(1,"instruction completed early");
        end
        if(dut.pc_value!==pc || dut.u_control.state!==dut.u_control.FETCH)
            $fatal(1,"wrong retirement PC or timing");
    endtask
    initial begin
        for(int i=0;i<256;i++) memory[i]=8'hFF;
        memory[0]=8'h12; memory[1]=8'h34; // Full 13-bit configuration.
        memory[2]=8'h39; // SET_DIR, no timer reference reset.
        memory[3]=0; memory[4]=8'h08; // WAIT_C 8.
        memory[5]=8'h20; memory[6]=8'h38; memory[7]=8'h20;
        memory[8]=0; memory[9]=2; // Reconfigure after the second WAIT.
        memory[10]=8'h20; // Already late: config fetch/execute exceeds T=2.
        memory[11]=0; memory[12]=0; // Illegal zero configuration.
        @(posedge clk); #1; @(negedge clk); reset=0;
        retire(3,2);
        if(dut.u_timer.t_reg!==13'h1234) $fatal(1,"WAIT_C lost upper bits");
        retire(2,3);
        if(dut.direction!==1) $fatal(1,"SET_DIR failed");
        retire(3,5); retire(9,6); // First WAIT: one fetch + 8 execution clocks.
        retire(2,7); retire(6,8); // Eight total clocks between WAIT completions.
        if(overrun!==0) $fatal(1,"unexpected overrun");
        retire(3,10); retire(2,11);
        if(overrun!==1) $fatal(1,"missed interval not reported");
        step(); step();
        repeat(3) begin
            step();
            if(dut.pc_value!==11 || dut.u_timer.t_reg!==2 || dut.wait_c_write!==0)
                $fatal(1,"WAIT_C zero must stall without changing T");
        end
        @(negedge clk); reset=1; step();
        if(overrun!==0 || dut.u_timer.epoch_valid!==0) $fatal(1,"reset failed");
        $display("PASS: WAIT_C legality, compensated WAIT, overrun and reset");
        $finish;
    end
    initial begin #10000; $fatal(1,"control integration timeout"); end
endmodule
