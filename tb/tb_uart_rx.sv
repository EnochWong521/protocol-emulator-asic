`timescale 1ns/1ps
module tb_uart_rx;
    localparam int T=868;
    logic clk=0, reset=1, rx=1;
    logic [7:0] memory[0:255];
    wire [7:0] addr;
    wire [7:0] inst=memory[addr];
    wire [3:0] value, enable;
    wire overrun;
    string program_file="examples/uart_rx_8n1.hex";
    int good_frames=0, bad_frames=0, samples=0;
    int cycle_count=0, previous_sample=0;
    logic [7:0] expected_byte;
    logic check_data=0;
    int sender_clocks=T, phase_index=0;
    time frame_started;
    longint sample_error;
    int phase_offsets[0:7]='{1,2,3,4,6,7,8,9};
    always #5 clk=~clk;
    protocol_core dut(.clk(clk),.reset(reset),.inst(inst),.inst_addr(addr),
        .gpio_in_async({2'b0,rx,1'b0}),.gpio_out_value(value),
        .gpio_out_enable(enable),.timing_overrun(overrun));
    always @(posedge clk) begin
        if (!reset) begin
            cycle_count++;
            if (dut.exec_shift_in) begin
                sample_error = longint'($time) - longint'(frame_started) -
                               (sender_clocks * 10 * (3 + 2*samples) / 2);
                if (sample_error < -(sender_clocks*10/8) || sample_error > sender_clocks*10/8)
                    $fatal(1,"RX sample was not within one eighth-bit of the expected center");
                if (samples > 0 && cycle_count-previous_sample != T)
                    $fatal(1,"RX samples are not exactly one local bit period apart");
                samples++; previous_sample=cycle_count;
            end
            if (dut.exec_mov_reg && dut.pc_value==8'h0E) begin
                if (!check_data || dut.r1_data !== expected_byte || samples != 8)
                    $fatal(1,"RX byte mismatch: got=%h expected=%h samples=%0d",dut.r1_data,expected_byte,samples);
                good_frames++;
            end
            if (dut.exec_shift_out && dut.pc_value==8'h12) bad_frames++;
        end
    end
    task automatic clocks(input int n);
        repeat(n) @(negedge clk);
    endtask
    task automatic frame(input logic[7:0] data,input bit valid_stop,input int sender_period);
        int old_good,old_bad;
        logic[7:0] retained_byte;
        old_good=good_frames; old_bad=bad_frames; retained_byte=dut.r0_data;
        expected_byte=data; check_data=valid_stop; samples=0;
        // Deliberately offset the input from the local sampling clock.
        #(phase_offsets[phase_index]); phase_index=(phase_index+1)%8;
        sender_clocks=sender_period; frame_started=$time;
        rx=0; #(sender_period*10);
        for(int i=0;i<8;i++) begin rx=data[i]; #(sender_period*10); end
        rx=valid_stop; #(sender_period*10);
        if (valid_stop) begin
            if(good_frames != old_good+1 || bad_frames != old_bad || dut.r0_data !== data || overrun !== 0)
                $fatal(1,"valid RX frame failed: byte=%h good=%0d bad=%0d overrun=%b",data,good_frames,bad_frames,overrun);
        end else begin
            if(good_frames != old_good || bad_frames != old_bad+1 || dut.r0_data !== retained_byte)
                $fatal(1,"bad stop bit was not rejected");
            rx=1; #(sender_period*10);
        end
        @(negedge clk);
    endtask
    initial begin
        if($value$plusargs("rx_program=%s",program_file)) begin end
        for(int i=0;i<256;i++) memory[i]=8'hFF;
        $readmemh(program_file,memory,0,21);
        if($test$plusargs("vcd")) begin $dumpfile("uart_rx.vcd"); $dumpvars(0,tb_uart_rx); end
        repeat(2) @(posedge clk); #1; @(negedge clk); reset=0;
        clocks(T*3); // Arbitrary initial idle interval.
        frame(8'h55,1,T);
        clocks(T*4+17); // Arbitrary gap before the next frame.
        frame(8'hA5,1,T);
        frame(8'h00,1,T); // Back-to-back frames (one stop bit).
        frame(8'hFF,1,T);
        frame(8'h01,1,T-8); // Approximately 1% faster/slower sender.
        frame(8'h80,1,T+8);
        clocks(T);
        // False start shorter than half a bit must not shift or report a frame.
        samples=0; rx=0; #(T*2); rx=1; #(T*15);
        if(good_frames!=6 || bad_frames!=0 || samples!=0)
            $fatal(1,"false start was accepted");
        frame(8'h3C,0,T);
        frame(8'hC3,1,T); // Recover from framing error without reset.
        if($test$plusargs("exhaustive")) begin
            for(int byte_value=0;byte_value<256;byte_value++)
                frame(8'(byte_value),1,T);
        end
        if(overrun!==0 || enable[1:0]!==0 || value[2]!==1 || value[3]!==1)
            $fatal(1,"RX status/pin ownership/overrun incorrect");
        $display("PASS: UART RX: %0d valid frames, %0d framing error; gaps, back-to-back, false start, +/-1%% baud and recovery",good_frames,bad_frames);
        $finish;
    end
    initial begin #30000000; $fatal(1,"RX test timeout"); end
endmodule
