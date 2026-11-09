// Controller/PC integration: atomic WAIT_C writes and exact WAIT cycle timing.
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
    int unsigned clock_edges = 0;
    int timing_wait_cases = 0;
    int timing_program_cases = 0;

    always @(posedge clk) clock_edges++;

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

    // Expected durations are supplied as literal reference-table values, not
    // derived from the timer's flags or arithmetic. Check every execution edge.
    task automatic run_wait_timing(input int unsigned t,
                                   input int unsigned full_d,
                                   input int unsigned half_d,
                                   input int unsigned quarter_d);
        logic [T_WIDTH-1:0] t_value;
        logic [PC_WIDTH-1:0] wait_pc;
        logic [INST_WIDTH-1:0] expected_ir;
        int unsigned program_first_edge, wait_first_edge, duration;
        int unsigned start_edges, tick_edges, measured_cycles;

        @(negedge clk);
        check_program = 0;
        reset = 1;
        t_value = T_WIDTH'(t);
        for (int i = 0; i < 256; i++)
            memory[i] = 8'hFF;
        memory[0] = {OP_WAIT_C, t_value[T_WIDTH-1:INST_WIDTH]};
        memory[1] = t_value[INST_WIDTH-1:0];
        memory[2] = {OP_WAIT, WAIT_FULL, WAIT_ARG_REQUIRED};
        memory[3] = {OP_WAIT, WAIT_HALF, WAIT_ARG_REQUIRED};
        memory[4] = {OP_WAIT, WAIT_QUARTER, WAIT_ARG_REQUIRED};
        @(posedge clk); #1;
        if (pc !== 0 || dut.state !== dut.FETCH || timer.wait_remaining !== '0)
            $fatal(1, "FAIL: reset before timing case T=%0d", t);
        @(negedge clk);
        reset = 0;
        program_first_edge = clock_edges;

        // WAIT_C takes exactly three edges and writes T only at EXECUTE.
        check_atomic_step(dut.FETCH_OPERAND, 8'd0, T_RESET_VALUE);
        check_atomic_step(dut.EXECUTE, 8'd0, T_RESET_VALUE);
        if (wait_c_write !== 1'b1 || t_write_data !== t_value || pc_sel !== PC_PLUS_2)
            $fatal(1, "FAIL: WAIT_C completion controls T=%0d", t);
        check_atomic_step(dut.FETCH, 8'd2, t_value);
        if (clock_edges - program_first_edge != 3)
            $fatal(1, "FAIL: WAIT_C did not take three cycles");

        for (int mode_index = 0; mode_index < 3; mode_index++) begin
            case (mode_index)
                0: duration = full_d;
                1: duration = half_d;
                default: duration = quarter_d;
            endcase
            wait_pc = PC_WIDTH'(2 + mode_index);
            expected_ir = memory[wait_pc];
            wait_first_edge = clock_edges;
            start_edges = 0;
            tick_edges = 0;

            // Exactly one fetch edge precedes the D execution edges.
            #1;
            if (dut.state !== dut.FETCH || pc !== wait_pc || inst_addr !== wait_pc ||
                pc_sel !== PC_HOLD || {wait_c_write, wait_start, wait_tick} !== 3'b000 ||
                timer.wait_remaining !== '0)
                $fatal(1, "FAIL: WAIT fetch T=%0d mode=%0d", t, mode_index);
            @(posedge clk); #1;
            if (dut.state !== dut.EXECUTE || pc !== wait_pc || dut.ir !== expected_ir)
                $fatal(1, "FAIL: WAIT fetch added/lost a cycle");

            for (int unsigned e = 0; e < duration; e++) begin
                #1;
                if (pc !== wait_pc || dut.ir !== expected_ir ||
                    dut.imm !== t_value[INST_WIDTH-1:0] || timer.t_reg !== t_value ||
                    wait_mode !== mode_index[1:0] || wait_c_write !== 1'b0)
                    $fatal(1, "FAIL: WAIT state changed early T=%0d mode=%0d edge=%0d",
                           t, mode_index, e);
                if (e == 0) begin
                    if (dut.state !== dut.EXECUTE || wait_start !== 1'b1 ||
                        wait_tick !== 1'b0 || wait_is_single_cycle !== (duration == 1) ||
                        timer.wait_duration !== T_WIDTH'(duration))
                        $fatal(1, "FAIL: first EXECUTE edge T=%0d mode=%0d", t, mode_index);
                end
                else begin
                    if (dut.state !== dut.WAIT_REMAIN || wait_start !== 1'b0 ||
                        wait_tick !== 1'b1 || timer.wait_remaining !== T_WIDTH'(duration-e) ||
                        wait_is_last_cycle !== (e == duration-1))
                        $fatal(1, "FAIL: countdown T=%0d mode=%0d edge=%0d", t, mode_index, e);
                end
                if (pc_sel !== ((e == duration-1) ? PC_PLUS_1 : PC_HOLD))
                    $fatal(1, "FAIL: PC selection before final WAIT edge");
                if (wait_start) start_edges++;
                if (wait_tick) tick_edges++;
                @(posedge clk); #1;
                if (timer.wait_remaining !== T_WIDTH'(duration-e-1) ||
                    timer.t_reg !== t_value || dut.ir !== expected_ir ||
                    dut.imm !== t_value[INST_WIDTH-1:0])
                    $fatal(1, "FAIL: post-edge countdown or retention");
                if (e == duration-1) begin
                    if (dut.state !== dut.FETCH || pc !== wait_pc + PC_WIDTH'(ONE_BYTE) ||
                        wait_is_last_cycle !== 1'b0 || pc_sel !== PC_HOLD)
                        $fatal(1, "FAIL: WAIT did not complete on its Dth execution edge");
                end
                else if (dut.state !== dut.WAIT_REMAIN || pc !== wait_pc)
                    $fatal(1, "FAIL: WAIT completed before its Dth execution edge");
            end
            if (start_edges != 1 || tick_edges != duration-1 ||
                clock_edges - wait_first_edge != duration+1)
                $fatal(1, "FAIL: expected one start, D-1 ticks and D+1 total cycles");
            timing_wait_cases++;
        end

        measured_cycles = clock_edges - program_first_edge;
        if (measured_cycles != 6 + full_d + half_d + quarter_d || pc !== 8'd5)
            $fatal(1, "FAIL: timing program total T=%0d cycles=%0d", t, measured_cycles);
        if (t == 434 && measured_cycles != 765)
            $fatal(1, "FAIL: reference program must take 765 cycles");
        timing_program_cases++;
        $display("PASS: T=%0d FULL=%0d HALF=%0d QUARTER=%0d; program=%0d cycles",
                 t, full_d, half_d, quarter_d, measured_cycles);
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
        $display("PASS: original WAIT program");
        $display("WAIT instructions: %0d", wait_count);
        $display("WAIT_C instructions: %0d", config_count);
        $display("Instruction completions: %0d in %0d active cycles", completed_count, active_cycles);
        $display("Final PC: %0d", pc);

        // Microarchitecture reference table: T, FULL D, HALF D, QUARTER D.
        run_wait_timing(1,       1,    1,    1);
        run_wait_timing(2,       2,    1,    1);
        run_wait_timing(3,       3,    1,    1);
        run_wait_timing(4,       4,    2,    1);
        run_wait_timing(7,       7,    3,    1);
        run_wait_timing(434,   434,  217,  108);
        run_wait_timing(8191, 8191, 4095, 2047);
        if (timing_wait_cases != 21 || timing_program_cases != 7)
            $fatal(1, "FAIL: timing coverage incomplete");
        $display("ALL TESTS PASSED: 21 WAIT timings, 7 WAIT_C timings, 765-cycle reference");
        $finish;
    end

    //timeout protection
    initial begin
        #500000;
        $fatal(1, "FAIL: simulation timeout");
    end

endmodule
