`timescale 1ns/1ps

// Single-controller I2C, P0=SCL and P1=SDA, through the real core and wired bus.
// Target behavior is driven only by observed bus edges, never CPU instructions.
// Pull-ups are modeled explicitly; delayed rising thresholds approximate loading.
module tb_i2c;
    logic clk=0, reset=1;
    logic [7:0] memory [0:255];
    wire [7:0] addr;
    wire [3:0] value, enable;
    wire overrun;
    tri1 raw_scl, raw_sda;
    wire scl, sda;
    logic target_scl_low=0, target_sda_low=0;
    int rise_ns=0, target_delay_ns=0;
    assign raw_scl = enable[0] ? value[0] : 1'bz;
    assign raw_sda = enable[1] ? value[1] : 1'bz;
    assign raw_scl = target_scl_low ? 1'b0 : 1'bz;
    assign raw_sda = target_sda_low ? 1'b0 : 1'bz;
    assign #(rise_ns, 0) scl=raw_scl;
    assign #(rise_ns, 0) sda=raw_sda;
    protocol_core dut (
        .clk(clk), .reset(reset), .inst(memory[addr]), .inst_addr(addr),
        .gpio_in_async({2'b00,sda,scl}), .gpio_out_value(value),
        .gpio_out_enable(enable), .timing_overrun(overrun)
    );
    always #4 clk=~clk; // 125 MHz

    typedef enum {RX_BITS, TARGET_ACK, TX_BITS, CONTROLLER_ACK, WAIT_STOP} target_state_t;
    target_state_t state=RX_BITS;
    bit active=0, ack_driven=0, ack_seen=0, send_ack=0, read_address=0;
    logic [7:0] received=0, write_byte=8'h10, read0=8'hA6, read1=8'h59;
    int bits=0, starts=0, stops=0, rx_bytes=0, tx_bytes=0, controller_acks=0;
    int half_clocks=625, nack_index=-1, stretch_at_fall=-1;
    int falls=0, stretches=0, blocked_clocks=0, cases_run=0;
    int done_pc, error_pc, image_size;
    int patch_count;
    int nack_patches [0:2];
    realtime last_rise=0, last_fall=0, last_data=0, first_start=0;
    realtime min_high, min_low, min_period, min_setup;
    realtime min_start_hold, min_start_setup, min_stop_setup;
    realtime observed_min_high, observed_min_low, observed_min_period;
    string program_file="examples/i2c_write_read.hex";

    function automatic logic read_bit(input int index);
        logic [7:0] data;
        data=(tx_bytes==0) ? read0 : read1;
        read_bit=data[7-index];
    endfunction

    // START and repeated START reset the target's partial address reception.
    always @(negedge sda) begin
        if (!reset && scl===1) begin
            if (starts>=2) $fatal(1, "Unexpected extra I2C START");
            if (active && rx_bytes!=2) $fatal(1, "Repeated START before write completed");
            if (active && $realtime-last_rise<min_start_setup)
                $fatal(1, "Repeated START setup time too short");
            active=1; starts++; bits=0; received=0; state=RX_BITS;
            ack_driven=0; ack_seen=0;
            if (starts==1) first_start=$realtime;
        end
    end

    always @(posedge sda) begin
        if (!reset && active && scl===1) begin
            stops++; active=0;
            if ($realtime-last_rise < min_stop_setup)
                $fatal(1, "I2C STOP setup time too short");
        end
    end

    always @(sda) last_data=$realtime;

    always @(posedge scl) begin
        if (!reset && active) begin
            if (last_fall!=0) begin
                if ($realtime-last_fall<min_low)
                    $fatal(1, "SCL LOW too short: %0.3f ns", $realtime-last_fall);
                if ($realtime-last_fall<observed_min_low) observed_min_low=$realtime-last_fall;
            end
            if (last_rise!=0) begin
                if ($realtime-last_rise<min_period)
                    $fatal(1, "SCL exceeds selected I2C mode rate: period %0.3f ns", $realtime-last_rise);
                if ($realtime-last_rise<observed_min_period) observed_min_period=$realtime-last_rise;
            end
            last_rise=$realtime;
            if (state!=WAIT_STOP && $realtime-last_data<min_setup)
                $fatal(1, "I2C SDA setup time too short");
            case (state)
                RX_BITS: begin
                    if (sda!==0 && sda!==1) $fatal(1, "Unknown SDA while receiving");
                    received={received[6:0],sda}; bits++;
                    if (bits==8) begin
                        case (rx_bytes)
                            0: if (received!==8'hA0) $fatal(1, "Wrong write address: %h",received);
                            1: if (received!==write_byte) $fatal(1, "Wrong write data: %h expected %h",received,write_byte);
                            2: if (received!==8'hA1) $fatal(1, "Wrong read address: %h",received);
                            default: $fatal(1, "Unexpected byte sent to target");
                        endcase
                        send_ack=(rx_bytes!=nack_index);
                        read_address=(rx_bytes==2);
                        rx_bytes++;
                        state=TARGET_ACK; ack_driven=0; ack_seen=0;
                    end
                end
                TARGET_ACK: begin
                    if (!ack_driven || enable[1]!==0 || sda!==!send_ack)
                        $fatal(1, "Controller did not release SDA for target ACK/NACK");
                    ack_seen=1;
                end
                TX_BITS: begin
                    if (enable[1]!==0 || sda!==read_bit(bits))
                        $fatal(1, "Controller drove SDA during read or target bit incorrect");
                    bits++;
                    if (bits==8) begin
                        state=CONTROLLER_ACK; ack_driven=0; ack_seen=0;
                    end
                end
                CONTROLLER_ACK: begin
                    if (!ack_driven || sda!==(tx_bytes!=0))
                        $fatal(1, "Expected controller ACK after first byte, NACK after second");
                    if (tx_bytes==0) controller_acks++;
                    tx_bytes++; ack_seen=1;
                end
                default: begin end
            endcase
        end
    end

    always @(negedge scl) begin
        if (!reset && active) begin
            if (last_rise!=0) begin
                if ($realtime-last_rise<min_high)
                    $fatal(1, "SCL HIGH too short: %0.3f ns", $realtime-last_rise);
                if ($realtime-last_rise<observed_min_high) observed_min_high=$realtime-last_rise;
            end else if ($realtime-first_start<min_start_hold)
                $fatal(1, "START hold time too short");
            last_fall=$realtime; falls++;
            if (falls==stretch_at_fall) begin
                target_scl_low=1;
                target_scl_low <= #(half_clocks*8*3+13) 0;
                stretches++;
            end
            case (state)
                TARGET_ACK: begin
                    if (!ack_driven) begin
                        target_sda_low <= #(target_delay_ns) send_ack;
                        ack_driven=1;
                    end else if (ack_seen) begin
                        bits=0; received=0;
                        if (!send_ack) begin
                            target_sda_low <= #(target_delay_ns) 0;
                            state=WAIT_STOP;
                        end else if (read_address) begin
                            state=TX_BITS;
                            target_sda_low <= #(target_delay_ns) !read_bit(0);
                        end else begin
                            target_sda_low <= #(target_delay_ns) 0;
                            state=RX_BITS;
                        end
                    end
                end
                TX_BITS: target_sda_low <= #(target_delay_ns) !read_bit(bits);
                CONTROLLER_ACK: begin
                    if (!ack_driven) begin
                        target_sda_low <= #(target_delay_ns) 0;
                        ack_driven=1;
                    end else if (ack_seen) begin
                        bits=0;
                        if (tx_bytes==1) begin
                            state=TX_BITS;
                            target_sda_low <= #(target_delay_ns) !read_bit(0);
                        end else begin
                            state=WAIT_STOP;
                            target_sda_low <= #(target_delay_ns) 0;
                        end
                    end
                end
                default: begin end
            endcase
        end
    end

    always @(posedge clk) begin
        #0.001;
        if (!reset) begin
            if ((enable[1:0] & value[1:0]) !== 0)
                $fatal(1, "I2C controller actively drove HIGH");
            if (overrun!==0) $fatal(1, "I2C firmware missed a WAIT deadline");
            if (target_scl_low && !enable[0] && dut.ir==8'h43 &&
                dut.u_control.state==dut.u_control.EXECUTE) begin
                blocked_clocks++;
                if (dut.gpio_in_sync[0]===0 && dut.pc_sel!==isa_pkg::PC_HOLD)
                    $fatal(1, "Controller ignored clock stretching");
            end
        end
    end

    // Catch even delta-cycle attempts to drive a HIGH against an open-drain target.
    always @(value or enable) begin
        if (!reset && (enable[1:0] & value[1:0]) !== 0)
            $fatal(1, "Open-drain pad attempted to drive HIGH between CPU edges");
    end

    task automatic emit(input logic [7:0] byte_value, inout int p);
        if (p>=256) $fatal(1, "I2C firmware exceeded 256 bytes");
        memory[p]=byte_value; p++;
    endtask

    task automatic raise_scl(inout int p);
        emit(8'h20,p); // LOW interval, counted since preceding WAIT completion.
        emit(8'hA1,p); // Logical HIGH releases open-drain SCL.
        emit(8'h43,p); // WAIT_PIN P0,HIGH: includes rise delay/stretch, rebases timer.
    endtask

    task automatic lower_scl(inout int p);
        emit(8'h20,p); // HIGH interval anchored to the observed physical HIGH.
        emit(8'hA0,p);
    endtask

    task automatic send_byte(input logic [7:0] data, inout int p);
        int bit_pc;
        emit(8'hC0,p); emit(data,p);
        bit_pc=p;
        emit(8'hA7,p); // SHIFT_OUT R0,P1,SHIFT, MSB first.
        raise_scl(p); lower_scl(p);
        emit(8'h68,p); emit(8'(bit_pc),p);
        emit(8'hA5,p); // Release SDA for ninth clock.
        raise_scl(p);
        emit(8'h4A,p); // BRANCH_PIN P1,HIGH,nack (outside counted bit loop).
        nack_patches[patch_count]=p; patch_count++;
        emit(0,p);
        lower_scl(p);
    endtask

    task automatic receive_byte(input bit last_byte, inout int p);
        int bit_pc;
        emit(8'hD0,p); emit(8'h5A,p); // Nonzero seed; eight samples replace it.
        emit(8'hA5,p); // Release SDA throughout incoming data.
        bit_pc=p;
        raise_scl(p);
        emit(8'h94,p); // SHIFT_IN R1,P1.
        lower_scl(p);
        emit(8'h68,p); emit(8'(bit_pc),p);
        emit(last_byte ? 8'hA5 : 8'hA4,p); // NACK or ACK ninth clock.
        raise_scl(p); lower_scl(p);
        emit(8'hA5,p);
    endtask

    task automatic stop_bus(inout int p);
        emit(8'hA0,p); emit(8'hA4,p); // SCL LOW before SDA LOW.
        raise_scl(p);
        emit(8'h20,p);
        emit(8'hA5,p); // SDA rising while SCL HIGH: STOP.
        emit(8'h20,p); // Bus-free hold.
    endtask

    task automatic make_program;
        int p;
        for (int i=0;i<256;i++) memory[i]=8'hFF;
        p=0; patch_count=0;
        emit(8'h56,p); emit(8'h03,p);
        emit(8'h39,p); // SET_DIR LEFT, I2C MSB first.
        emit(8'(half_clocks>>8),p); emit(8'(half_clocks),p);
        emit(8'hA5,p); emit(8'hA1,p); // Release SDA and SCL.
        emit(8'h4B,p); emit(8'h43,p); // Wait for both physical lines HIGH.
        emit(8'h20,p); emit(8'hA4,p); // START after bus-free interval.
        lower_scl(p);
        send_byte(8'hA0,p); send_byte(write_byte,p);
        // Repeated START: release SDA while SCL LOW, then pull SDA LOW while HIGH.
        emit(8'hA5,p); raise_scl(p);
        emit(8'h20,p); emit(8'hA4,p); lower_scl(p);
        send_byte(8'hA1,p);
        receive_byte(0,p);
        emit(8'hC8,p); // Save first received byte in R0.
        receive_byte(1,p);
        stop_bus(p);
        emit(8'hA9,p); // P2 success marker.
        done_pc=p; emit(8'h44,p); emit(8'(done_pc),p);
        error_pc=p;
        emit(8'h20,p); // A NACK branch occurs with SCL HIGH: finish that HIGH phase.
        stop_bus(p);
        emit(8'hAD,p); // P3 NACK marker.
        emit(8'h44,p); emit(8'(p-1),p); // Self-jump at the JMP opcode.
        for (int i=0;i<patch_count;i++) memory[nack_patches[i]]=8'(error_pc);
        image_size=p;
    endtask

    task automatic start_case(input bit load_example=0);
        @(negedge clk); reset=1;
        active=0; target_sda_low=0; target_scl_low=0;
        repeat (4) @(negedge clk);
        if (enable!==0 || dut.u_shift.open_drain_mask!==0)
            $fatal(1, "I2C reset did not release pads/reset modes");
        make_program();
        if (load_example) $readmemh(program_file,memory);
        starts=0; stops=0; rx_bytes=0; tx_bytes=0; controller_acks=0;
        falls=0; stretches=0; blocked_clocks=0; bits=0;
        last_rise=0; last_fall=0; last_data=0;
        observed_min_high=1e12; observed_min_low=1e12; observed_min_period=1e12;
        if (half_clocks==625) begin
            min_high=4000; min_low=4700; min_period=10000; min_setup=250;
            min_start_hold=4000; min_start_setup=4700; min_stop_setup=4000;
        end else begin
            min_high=600; min_low=1300; min_period=2500; min_setup=100;
            min_start_hold=600; min_start_setup=600; min_stop_setup=600;
        end
        @(negedge clk); reset=0;
    endtask

    task automatic finish_case;
        bit completed;
        completed=0;
        for (int cycle=0;cycle<140*half_clocks+1000 && !completed;cycle++) begin
            @(negedge clk);
            completed=stops==1 && ((value[2] && enable[2]) || (value[3] && enable[3]));
        end
        if (!completed || scl!==1 || sda!==1 || enable[1:0]!==0 || stops!=1)
            $fatal(1, "I2C timeout/STOP/bus-release failure at PC=%h IR=%h",addr,dut.ir);
        if (nack_index<0) begin
            if (starts!=2 || rx_bytes!=3 || tx_bytes!=2 || controller_acks!=1 ||
                dut.r0_data!==read0 || dut.r1_data!==read1 || value[3:2]!==2'b01)
                $fatal(1, "I2C transaction mismatch: START=%0d RX=%0d TX=%0d ACK=%0d R0=%h/%h R1=%h/%h markers=%b",
                       starts,rx_bytes,tx_bytes,controller_acks,dut.r0_data,read0,dut.r1_data,read1,value[3:2]);
        end else if (rx_bytes!=nack_index+1 || tx_bytes!=0 || value[3:2]!==2'b10)
            $fatal(1, "I2C did not recover from NACK at byte %0d",nack_index);
        if (stretch_at_fall>0 && (stretches!=1 || blocked_clocks==0))
            $fatal(1, "Stretch test did not actually block the controller");
        cases_run++;
    endtask

    initial begin
        if ($value$plusargs("i2c_program=%s",program_file)) begin end
        if ($test$plusargs("emit_program")) begin
            make_program();
            $writememh("i2c_write_read.hex",memory);
            $display("I2C example image=%0d bytes, done=%h error=%h",image_size,done_pc,error_pc);
            $finish;
        end
        if ($test$plusargs("vcd")) begin
            $dumpfile("i2c.vcd"); $dumpvars(0,tb_i2c);
        end
        start_case(1); finish_case();
        $display("PASS: example ROM, write 10/read A6,59, repeated START, ACK then NACK, STOP; min SCL high/low=%0.0f/%0.0f ns",observed_min_high,observed_min_low);
        if (!$test$plusargs("vcd")) begin
            for (int speed=0;speed<2;speed++) begin
                half_clocks=speed ? 163 : 625;
                for (int loading=0;loading<2;loading++) begin
                    rise_ns=loading ? 80 : 0;
                    target_delay_ns=loading ? 17 : 0;
                    for (int stretch=0;stretch<3;stretch++) begin
                        // Stretch both outgoing address and incoming data clocks.
                        case (stretch)
                            0: stretch_at_fall=-1;
                            1: stretch_at_fall=4;
                            2: stretch_at_fall=34;
                        endcase
                        for (int pattern=0;pattern<4;pattern++) begin
                            write_byte=8'(pattern*85); read0=write_byte^8'hA6; read1=~write_byte;
                            start_case(); finish_case();
                        end
                    end
                end
                // NACK at write address, write data and repeated-START read address.
                stretch_at_fall=4;
                for (int rejected=0;rejected<3;rejected++) begin
                    nack_index=rejected; start_case(); finish_case();
                end
                nack_index=-1;
                $display("PASS: %s timing, delayed pull-ups/target, stretching and all three target-NACK paths",
                         speed ? "Fast-mode <=400 kHz" : "Standard-mode <=100 kHz");
            end
            // Every write/read byte at the conservative Fast-mode timing.
            half_clocks=163; rise_ns=80; target_delay_ns=17; stretch_at_fall=26;
            for (int data=0;data<256;data++) begin
                write_byte=8'(data); read0=write_byte^8'hA6; read1=~write_byte;
                start_case(); finish_case();
            end
            $display("PASS: every 8-bit write value and both read-byte values, asynchronous stretch during read-address phase");
            // Abort while SCL is physically stretched, then recover on a new run.
            start_case();
            wait (blocked_clocks>2);
            @(negedge clk); reset=1; active=0;
            repeat (4) @(negedge clk);
            if (enable!==0 || dut.u_shift.open_drain_mask!==0 || addr!==0)
                $fatal(1, "Reset during stretch failed");
            // Let the outstanding target release complete before starting a fresh transaction.
            #(half_clocks*8*4);
            stretch_at_fall=-1; start_case(); finish_case();
            $display("PASS: reset during clock stretch and subsequent transaction recovery");
        end
        $display("PASS: %0d I2C write/repeated-START/two-byte-read or NACK transactions; no active HIGH or timing overrun",cases_run);
        $finish;
    end
    initial begin #300000000; $fatal(1,"I2C suite global timeout"); end
endmodule
