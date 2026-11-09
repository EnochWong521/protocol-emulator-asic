// Controller/PC integration with the real WAIT timer and atomic WAIT_C checks.
// Run from the repository root:
// iverilog -g2012 -s tb_control_unit -o /tmp/tb_control_unit.vvp \
//   rtl/isa_pkg.sv rtl/pc.sv rtl/wait_timer.sv rtl/control_unit.sv tb/tb_control_unit.sv
// vvp /tmp/tb_control_unit.vvp
`timescale 1ns/1ps

module tb_control_unit;
    import isa_pkg::*;

    logic [7:0] inst;
    logic       clk;
    logic       reset;
    logic       wait_is_single_cycle;
    logic       wait_is_last_cycle;

    logic       wait_start;
    logic       wait_c_write;
    logic       wait_tick;
    logic [T_WIDTH-1:0] t_write_data;
    logic [1:0] wait_mode;
    logic [1:0] pc_sel;
    logic       direction;

    //program counter and instruction memory
    logic [7:0] pc;
    logic [7:0] inst_addr;
    logic [7:0] memory [0:255];

    // Enable the program scoreboard after the directed atomic-write checks.
    bit check_program = 1'b0;

    //test counters
    integer wait_count;
    integer config_count;
    integer expected_duration;
    integer completed_count;
    integer active_cycles;

    //control unit
    control_unit dut (
        .inst(inst),
        .pc_value(pc),
        .clk(clk),
        .reset(reset),
        .wait_is_single_cycle(wait_is_single_cycle),
        .wait_is_last_cycle(wait_is_last_cycle),

        .wait_start(wait_start),
        .wait_c_write(wait_c_write),
        .t_write_data(t_write_data),
        .wait_mode(wait_mode),
        .wait_tick(wait_tick),
        .pc_sel(pc_sel),
        .inst_addr(inst_addr),
        .direction(direction)
    );

    //clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    task automatic load_wait_program;
        for(integer i = 0; i < 256; i = i + 1)
            memory[i] = 8'hFF;

        memory[0] = 8'h00; //WAIT_C 4 upper
        memory[1] = 8'h04; //WAIT_C 4 lower
        memory[2] = 8'h20; //WAIT FULL
        memory[3] = 8'h28; //WAIT HALF
        memory[4] = 8'h30; //WAIT QUARTER
        memory[5] = 8'h00; //WAIT_C 8 upper
        memory[6] = 8'h08; //WAIT_C 8 lower
        memory[7] = 8'h20; //WAIT FULL
    endtask

    task automatic check_atomic_step(input logic [1:0] expected_state,
                                     input logic [7:0] expected_pc,
                                     input logic [T_WIDTH-1:0] expected_t);
        @(posedge clk); #1;
        if (dut.state !== expected_state || pc !== expected_pc || timer.t_reg !== expected_t)
            $fatal(1, "FAIL: atomic sequence state=%b PC=%h T=%h",
                   dut.state, pc, timer.t_reg);
    endtask

    //combinational instruction-memory read
    assign inst = memory[inst_addr];

    // Separate PC block owns increment selection and storage.
    pc u_pc (
        .clk         (clk),
        .reset       (reset),
        .pc_sel      (pc_sel),
        .pc          (pc)
    );

    wait_timer timer (
        .clk(clk), .rst(reset),
        .wait_c_write(wait_c_write), .t_write_data(t_write_data),
        .wait_start(wait_start), .wait_mode(wait_mode), .wait_tick(wait_tick),
        .wait_is_single_cycle(wait_is_single_cycle),
        .wait_is_last_cycle(wait_is_last_cycle)
    );

    // Check the full T register on every edge, including both fetch states.
    always @(posedge clk) begin : check_timer_interface
        logic [T_WIDTH-1:0] expected_t;
        expected_t = timer.t_reg;
        if (reset) begin
            expected_t = T_RESET_VALUE;
            if (pc_sel !== PC_HOLD || {wait_c_write, wait_start, wait_tick} !== 3'b000)
                $fatal(1, "FAIL: command during reset");
        end
        else begin
            if ((wait_c_write && (wait_start || wait_tick)) || (wait_start && wait_tick))
                $fatal(1, "FAIL: concurrent timer commands");
            if (wait_c_write) begin
                if (dut.state !== dut.EXECUTE ||
                    dut.ir[OPCODE_MSB:OPCODE_LSB] !== OP_WAIT_C || t_write_data === '0)
                    $fatal(1, "FAIL: invalid or premature WAIT_C write");
                expected_t = t_write_data;
            end
            if (wait_start &&
                (dut.state !== dut.EXECUTE ||
                 dut.ir[OPCODE_MSB:OPCODE_LSB] !== OP_WAIT ||
                 wait_mode == SET_DIR ||
                 dut.ir[WAIT_ARG_MSB:WAIT_ARG_LSB] !== WAIT_ARG_REQUIRED))
                $fatal(1, "FAIL: timer started by a non-WAIT instruction");
            if (wait_tick && (dut.state !== dut.WAIT_REMAIN || timer.wait_remaining === '0))
                $fatal(1, "FAIL: invalid countdown tick");
        end
        #1;
        if (timer.t_reg !== expected_t)
            $fatal(1, "FAIL: T changed without an atomic write");
    end

    // Check the program's literal completion addresses and exact total latency.
    // Inspect PC after nonblocking register updates have taken effect.
    always @(posedge clk) begin : check_pc_completion
        logic [7:0] expected_pc;
        logic [1:0] expected_sel;
        if (reset || check_program) begin
            if (reset) begin
                expected_pc = 0;
                completed_count = 0;
                active_cycles = 0;
            end
            else begin
                active_cycles++;
                expected_pc = pc;
                if (pc_sel != PC_HOLD) begin
                    case (completed_count)
                        0: begin expected_pc = 2; expected_sel = PC_PLUS_2; end
                        1: begin expected_pc = 3; expected_sel = PC_PLUS_1; end
                        2: begin expected_pc = 4; expected_sel = PC_PLUS_1; end
                        3: begin expected_pc = 5; expected_sel = PC_PLUS_1; end
                        4: begin expected_pc = 7; expected_sel = PC_PLUS_2; end
                        5: begin expected_pc = 8; expected_sel = PC_PLUS_1; end
                        default: $fatal(1, "FAIL: extra instruction completion");
                    endcase
                    if (pc_sel !== expected_sel)
                        $fatal(1, "FAIL: wrong PC increment for instruction");
                    if ((dut.state == dut.WAIT_REMAIN && !wait_is_last_cycle) ||
                        (wait_start && !wait_is_single_cycle))
                        $fatal(1, "FAIL: PC advanced before WAIT completed");
                    completed_count++;
                end
            end
            #1;
            if (pc !== expected_pc)
                $fatal(1, "FAIL: PC=%0d expected=%0d", pc, expected_pc);
        end
    end

    //check control signals
    always @(posedge clk) begin
        if(reset == 0 && check_program) begin

            // Fetching changes the memory address, never the architectural PC.
            if(pc_sel != PC_HOLD &&
               (dut.state == dut.FETCH ||
                dut.state == dut.FETCH_OPERAND))
                $fatal(1, "FAIL: PC updated during fetch");

            //timer should only start during execute
            if(wait_start == 1) begin

                if(dut.state != dut.EXECUTE)
                    $fatal(1, "FAIL: WAIT started outside EXECUTE");

                case(wait_count)
                    0: expected_duration = 4;
                    1: expected_duration = 2;
                    2: expected_duration = 1;
                    3: expected_duration = 8;
                    default: expected_duration = -1;
                endcase

                if(timer.wait_duration !== T_WIDTH'(expected_duration))
                    $fatal(1, "FAIL: incorrect WAIT duration");

                wait_count = wait_count + 1;

                $display("PASS: WAIT started, duration = %0d",
                         timer.wait_duration);
            end

            if(wait_c_write) begin
                case (config_count)
                    0: if (t_write_data !== 13'd4) $fatal(1, "FAIL: first T value");
                    1: if (t_write_data !== 13'd8) $fatal(1, "FAIL: second T value");
                    default: $fatal(1, "FAIL: extra WAIT_C write");
                endcase
                config_count = config_count + 1;
                $display("PASS: atomic WAIT_C write, T=%0d", t_write_data);
            end

        end
    end

    //run test
    initial begin
        reset = 1;
        wait_count = 0;
        config_count = 0;
        expected_duration = 0;
        for (int i = 0; i < 256; i++)
            memory[i] = 8'hFF;
        memory[0] = 8'h12; // WAIT_C 13'h1234: both upper and lower bits change.
        memory[1] = 8'h34;
        memory[2] = 8'h39; // SET_DIR LEFT must not touch the timer.
        memory[3] = 8'h00; // Invalid WAIT_C zero must preserve the programmed T.
        memory[4] = 8'h00;

        $dumpfile("control_unit.vcd");
        $dumpvars(0, tb_control_unit);

        repeat(2) @(negedge clk);
        reset = 0;

        // T remains at reset value through both fetch edges, then loads at EXECUTE.
        check_atomic_step(dut.FETCH_OPERAND, 8'd0, T_RESET_VALUE);
        check_atomic_step(dut.EXECUTE, 8'd0, T_RESET_VALUE);
        if (t_write_data !== 13'h1234 || wait_c_write !== 1'b1)
            $fatal(1, "FAIL: assembled 13-bit write data or enable");
        check_atomic_step(dut.FETCH, 8'd2, 13'h1234);
        check_atomic_step(dut.EXECUTE, 8'd2, 13'h1234);
        check_atomic_step(dut.FETCH, 8'd3, 13'h1234);
        if (direction !== DIR_LEFT || timer.wait_remaining !== '0)
            $fatal(1, "FAIL: SET_DIR affected the timer");
        check_atomic_step(dut.FETCH_OPERAND, 8'd3, 13'h1234);
        check_atomic_step(dut.EXECUTE, 8'd3, 13'h1234);
        repeat (2)
            check_atomic_step(dut.EXECUTE, 8'd3, 13'h1234);
        if ({wait_c_write, wait_start, wait_tick} !== 3'b000)
            $fatal(1, "FAIL: invalid WAIT_C emitted a timer command");
        $display("PASS: atomic 13-bit T write; SET_DIR and WAIT_C zero preserve T");

        @(negedge clk);
        reset = 1;
        load_wait_program();
        @(posedge clk); #1;
        if (pc !== 0 || timer.t_reg !== T_RESET_VALUE || direction !== DIR_RIGHT)
            $fatal(1, "FAIL: reset before WAIT program");
        @(negedge clk);
        check_program = 1;
        reset = 0;

        //finish after final WAIT completes
        wait(pc == 8 && dut.state == dut.FETCH);

        #1;

        if(wait_count != 4)
            $fatal(1, "FAIL: expected 4 WAIT instructions");

        if(completed_count != 6 || active_cycles != 25)
            $fatal(1, "FAIL: expected 6 completions in exactly 25 active cycles");

        if(config_count != 2)
            $fatal(1, "FAIL: expected 2 WAIT_C instructions");

        if(timer.t_reg !== 13'd8)
            $fatal(1, "FAIL: final timer configuration incorrect");

        if(timer.wait_remaining !== '0)
            $fatal(1, "FAIL: timer did not finish");

        $display("");
        $display("ALL TESTS PASSED");
        $display("WAIT instructions: %0d", wait_count);
        $display("WAIT_C instructions: %0d", config_count);
        $display("Instruction completions: %0d in %0d active cycles", completed_count, active_cycles);
        $display("Final PC: %0d", pc);

        $finish;
    end

    //timeout protection
    initial begin
        #2000;
        $fatal(1, "FAIL: simulation timeout");
    end

endmodule
