// Multi-instruction WAIT regression using the legacy fake timer interface.
`timescale 1ns/1ps

module tb_control_unit;
    import isa_pkg::*;

    logic [7:0] inst;
    logic       clk;
    logic       reset;
    logic       wait_done;

    logic       wait_start;
    logic       wait_config_U;
    logic       wait_config_L;
    logic [1:0] pc_sel;

    //program counter and instruction memory
    logic [7:0] pc;
    logic [7:0] inst_addr;
    logic [7:0] memory [0:255];

    //fake WAIT timer
    logic [4:0]  config_U;
    logic [12:0] T;
    logic [12:0] wait_remaining;
    logic [12:0] wait_duration;
    logic [1:0]  wait_mode;
    logic        busy;

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
        .wait_done(wait_done),

        .wait_start(wait_start),
        .wait_config_U(wait_config_U),
        .wait_config_L(wait_config_L),
        .pc_sel(pc_sel),
        .inst_addr(inst_addr),
        .direction()
    );

    //clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    //instruction memory
    initial begin
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
    end

    //combinational instruction-memory read
    assign inst = memory[inst_addr];

    // Separate PC block owns increment selection and storage.
    pc u_pc (
        .clk         (clk),
        .reset       (reset),
        .pc_sel      (pc_sel),
        .pc          (pc)
    );

    //fake timer duration calculation
    always_comb begin
        case(wait_mode)
            2'b00: wait_duration = T;
            2'b01: wait_duration = T >> 1;
            2'b10: wait_duration = T >> 2;
            default: wait_duration = 13'd1;
        endcase

        if(wait_duration == 0)
            wait_duration = 13'd1;
    end

    //fake timer
    always_ff @(posedge clk) begin
        if(reset == 1) begin
            config_U <= 0;
            T <= 13'd4;
            wait_mode <= 0;
            wait_remaining <= 0;
            busy <= 0;
        end
        else begin

            //capture WAIT_C upper bits
            if(wait_config_U == 1)
                config_U <= inst[4:0];

            //capture WAIT_C lower bits
            if(wait_config_L == 1)
                T <= {config_U, inst[7:0]};

            //capture WAIT mode during FETCH
            if(dut.state == dut.FETCH &&
               inst[7:5] == 3'b001)
                wait_mode <= inst[4:3];

            //start timer
            if(wait_start == 1) begin
                wait_remaining <= wait_duration - 1;

                if(wait_duration == 1)
                    busy <= 0;
                else
                    busy <= 1;
            end

            //continue countdown
            else if(busy == 1) begin
                wait_remaining <= wait_remaining - 1;

                if(wait_remaining == 1)
                    busy <= 0;
            end
        end
    end

    // Completion status is independent of wait_start to avoid combinational
    // feedback between the fake timer and the controller.
    assign wait_done = ((dut.state == dut.EXECUTE) && (wait_duration == 13'd1)) ||
                       (busy && (wait_remaining == 13'd1));

    // Check the program's literal completion addresses and exact total latency.
    // Inspect PC after nonblocking register updates have taken effect.
    always @(posedge clk) begin : check_pc_completion
        logic [7:0] expected_pc;
        logic [1:0] expected_sel;
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
                if ((dut.state == dut.WAIT_REMAIN || wait_start) && !wait_done)
                    $fatal(1, "FAIL: PC advanced before WAIT completed");
                completed_count++;
            end
        end
        #1;
        if (pc !== expected_pc)
            $fatal(1, "FAIL: PC=%0d expected=%0d", pc, expected_pc);
    end

    //check control signals
    always @(posedge clk) begin
        if(reset == 0) begin

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

                if(wait_duration != expected_duration)
                    $fatal(1, "FAIL: incorrect WAIT duration");

                wait_count = wait_count + 1;

                $display("PASS: WAIT started, duration = %0d",
                         wait_duration);
            end

            //check upper configuration
            if(wait_config_U == 1) begin
                if(dut.state != dut.FETCH)
                    $fatal(1, "FAIL: upper config outside FETCH");

                $display("PASS: WAIT_C upper byte");
            end

            //check lower configuration
            if(wait_config_L == 1) begin
                if(dut.state != dut.FETCH_OPERAND)
                    $fatal(1, "FAIL: lower config outside FETCH_OPERAND");

                config_count = config_count + 1;

                $display("PASS: WAIT_C lower byte");
            end

        end
    end

    //run test
    initial begin
        reset = 1;
        wait_count = 0;
        config_count = 0;
        expected_duration = 0;

        $dumpfile("control_unit.vcd");
        $dumpvars(0, tb_control_unit);

        repeat(2) @(negedge clk);
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

        if(T != 8)
            $fatal(1, "FAIL: final timer configuration incorrect");

        if(wait_remaining != 0 || busy != 0)
            $fatal(1, "FAIL: timer did not finish");

        $display("");
        $display("ALL TESTS PASSED");
        $display("WAIT instructions: %0d", wait_count);
        $display("WAIT_C instructions: %0d", config_count);
        $display("Final PC: %0d", pc);

        $finish;
    end

    //timeout protection
    initial begin
        #2000;
        $fatal(1, "FAIL: simulation timeout");
    end

endmodule
