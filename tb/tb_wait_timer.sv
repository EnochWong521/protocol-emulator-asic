`timescale 1ns/1ps

module tb_wait_timer;

    localparam logic [1:0] WAIT_FULL    = 2'b00;
    localparam logic [1:0] WAIT_HALF    = 2'b01;
    localparam logic [1:0] WAIT_QUARTER = 2'b10;
    localparam logic [1:0] SET_DIR      = 2'b11;

    logic clk = 1'b0;
    logic rst;
    logic wait_c_write;
    logic [12:0] t_write_data;
    logic wait_start;
    logic [1:0] wait_mode;
    logic wait_tick;
    logic wait_is_single_cycle;
    logic wait_is_last_cycle;

    int tests_passed = 0;

    always #5 clk = ~clk;  // 100 MHz test clock (timer counts clock cycles)

    // Works with either the original README module (with debug output ports)
    // or the simplified module (internal-only t_reg/wait_remaining/wait_duration).
    wait_timer dut (
        .clk                  (clk),
        .rst                  (rst),
        .wait_c_write         (wait_c_write),
        .t_write_data         (t_write_data),
        .wait_start           (wait_start),
        .wait_mode            (wait_mode),
        .wait_tick            (wait_tick),
        .wait_is_single_cycle (wait_is_single_cycle),
        .wait_is_last_cycle   (wait_is_last_cycle)
    );

    // Hierarchical DUT checks: these three signals must have these names.
    task automatic check13(input string what,
                           input logic [12:0] actual,
                           input logic [12:0] expected);
        if (actual !== expected)
            $fatal(1, "FAIL @ %0t: %s actual=%0d expected=%0d",
                   $time, what, actual, expected);
    endtask

    task automatic check1(input string what,
                          input logic actual,
                          input logic expected);
        if (actual !== expected)
            $fatal(1, "FAIL @ %0t: %s actual=%b expected=%b",
                   $time, what, actual, expected);
    endtask

    function automatic int unsigned duration_for(
        input int unsigned t, input logic [1:0] mode
    );
        int unsigned shifted;
        case (mode)
            WAIT_FULL:    shifted = t;
            WAIT_HALF:    shifted = t >> 1;
            WAIT_QUARTER: shifted = t >> 2;
            default:      shifted = 0;
        endcase
        if (mode == SET_DIR)
            duration_for = 0;
        else if (shifted == 0)
            duration_for = 1;
        else
            duration_for = shifted;
    endfunction

    // New drive values on falling edges, inspect registered values after rising edges.
    task automatic reset_dut;
        @(negedge clk);
        rst          = 1'b1;
        wait_c_write = 1'b0;
        wait_start   = 1'b0;
        wait_tick    = 1'b0;
        wait_mode    = WAIT_FULL;
        t_write_data = '0;
        @(posedge clk);
        #1;
        check13("reset T", dut.t_reg, 13'd4);
        check13("reset remaining", dut.wait_remaining, 13'd0);
        check1("reset last-cycle flag", wait_is_last_cycle, 1'b0);
        @(negedge clk);
        rst = 1'b0;
        $display("PASS: reset");
        tests_passed++;
    endtask

    task automatic load_t(input int unsigned t);
        @(negedge clk);
        t_write_data = t[12:0];
        wait_c_write = 1'b1;
        @(posedge clk);
        #1;
        check13("WAIT_C load", dut.t_reg, t[12:0]);
        @(negedge clk);
        wait_c_write = 1'b0;
    endtask

    // Checks full WAIT behavior, including the EXECUTE/load cycle.
    task automatic run_wait(input int unsigned t,
                            input logic [1:0] mode);
        int unsigned d;
        d = duration_for(t, mode);
        load_t(t);

        @(negedge clk);
        wait_mode = mode;
        #1;  // Allow combinational duration/flags to settle
        check13("selected duration", dut.wait_duration, d[12:0]);
        check1("single-cycle before EXECUTE edge",
               wait_is_single_cycle, (d == 1));

        wait_start = 1'b1;
        @(posedge clk);  // EXECUTE edge counts as cycle 1 of D
        #1;
        check13("remaining after wait_start", dut.wait_remaining, (d-1));
        check13("T preserved on wait_start", dut.t_reg, t[12:0]);
        check1("last-cycle after wait_start", wait_is_last_cycle, (d == 2));
        @(negedge clk);
        wait_start = 1'b0;

        // Exactly D-1 WAIT_REMAIN cycles must follow the EXECUTE cycle.
        for (int unsigned r = d-1; r > 0; r--) begin
            #1;
            check13("remaining before tick", dut.wait_remaining, r[12:0]);
            check1("last-cycle BEFORE tick", wait_is_last_cycle, (r == 1));
            wait_tick = 1'b1;
            @(posedge clk);
            #1;
            check13("remaining after tick", dut.wait_remaining, (r-1));
            check1("last-cycle AFTER tick", wait_is_last_cycle, (r == 2));
            check13("T preserved through countdown", dut.t_reg, t[12:0]);
            @(negedge clk);
            wait_tick = 1'b0;
        end

        #1;
        check13("final remaining", dut.wait_remaining, 13'd0);
        check1("last flag low at zero", wait_is_last_cycle, 1'b0);
        tests_passed++;
        $display("PASS: T=%0d mode=%b D=%0d (D execution cycles)", t, mode, d);
    endtask

    task automatic test_t_hold_and_rewrite;
        load_t(434);
        @(negedge clk);
        t_write_data = 13'd777;  // Must NOT write without enable
        repeat (3) begin
            @(posedge clk);
            #1;
            check13("T retains value without write", dut.t_reg, 13'd434);
        end
        load_t(123);
        check13("T reprogramming", dut.t_reg, 13'd123);
        tests_passed++;
        $display("PASS: T hold and reconfiguration");
    endtask

    task automatic test_set_dir_and_counter_hold;
        load_t(7);
        @(negedge clk);
        wait_mode  = WAIT_FULL;
        wait_start = 1'b1;
        @(posedge clk);
        #1;
        check13("hold-test initial counter", dut.wait_remaining, 13'd6);
        @(negedge clk);
        wait_start = 1'b0;
        wait_mode  = SET_DIR; // Legal only with wait_start=0
        #1;
        check13("SET_DIR duration", dut.wait_duration, 13'd0);
        check1("SET_DIR not single-cycle WAIT", wait_is_single_cycle, 1'b0);
        repeat (3) begin
            @(posedge clk);
            #1;
            check13("counter holds without tick", dut.wait_remaining, 13'd6);
            check13("SET_DIR does not change T", dut.t_reg, 13'd7);
        end
        @(negedge clk);
        wait_mode = WAIT_QUARTER; // Mode changes must not reload countdown
        #1;
        check13("mode change does not touch counter", dut.wait_remaining, 13'd6);
        check13("new combinational duration", dut.wait_duration, 13'd1);
        wait_mode = WAIT_FULL;

        // Finish the old FULL delay using the remaining six ticks.
        for (int r = 6; r > 0; r--) begin
            @(negedge clk);
            wait_tick = 1'b1;
            #1;
            check1("last flag in held-countdown test",
                   wait_is_last_cycle, (r == 1));
            @(posedge clk);
            #1;
            check13("held-countdown resumes", dut.wait_remaining, (r-1));
            @(negedge clk);
            wait_tick = 1'b0;
        end
        tests_passed++;
        $display("PASS: SET_DIR, counter hold, and mode independence");
    endtask

    task automatic test_reset_during_wait;
        load_t(9);
        @(negedge clk);
        wait_mode  = WAIT_FULL;
        wait_start = 1'b1;
        @(posedge clk);
        #1;
        check13("mid-WAIT before reset", dut.wait_remaining, 13'd8);
        @(negedge clk);
        wait_start = 1'b0;
        wait_tick  = 1'b1;
        @(posedge clk);
        #1;
        check13("mid-WAIT tick", dut.wait_remaining, 13'd7);
        @(negedge clk);
        rst          = 1'b1;   // Reset wins even if commands remain asserted
        wait_c_write = 1'b1;
        t_write_data = 13'd999;
        @(posedge clk);
        #1;
        check13("reset overwrites T", dut.t_reg, 13'd4);
        check13("reset clears active countdown", dut.wait_remaining, 13'd0);
        @(negedge clk);
        rst          = 1'b0;
        wait_tick    = 1'b0;
        wait_c_write = 1'b0;
        tests_passed++;
        $display("PASS: synchronous reset during WAIT");
    endtask

    // Check illegal controller strobes. Intentional reset-overlap is allowed.
    always @(posedge clk) begin
        if (!rst) begin
            if ((wait_start && wait_tick) ||
                (wait_start && wait_c_write) ||
                (wait_tick && wait_c_write))
                $fatal(1, "Illegal concurrent timer commands");
            if (wait_tick && (dut.wait_remaining == 0))
                $fatal(1, "Illegal tick with zero remaining");
            if (wait_start && (wait_mode == SET_DIR))
                $fatal(1, "Illegal wait_start for SET_DIR");
        end
    end

    initial begin
        rst = 0;
        wait_c_write = 0;
        t_write_data = 0;
        wait_start = 0;
        wait_mode = WAIT_FULL;
        wait_tick = 0;

        $dumpfile("wait_timer.vcd");
        $dumpvars(0, tb_wait_timer);

        reset_dut();
        test_t_hold_and_rewrite();

        // Exhaustive directed cross-product of useful boundary values and modes.
        for (int ti = 0; ti < 7; ti++) begin
            int unsigned t;
            case (ti)
                0: t = 1;
                1: t = 2;
                2: t = 3;
                3: t = 4;
                4: t = 7;
                5: t = 434;
                6: t = 8191;
            endcase
            for (int m = 0; m < 3; m++)
                run_wait(t, m[1:0]);
        end

        test_set_dir_and_counter_hold();
        test_reset_during_wait();

        $display("\nALL %0d TESTS PASSED\n", tests_passed);
        $finish;
    end

    // Deadlock protection if testbench or DUT fails to progress.
    initial begin
        #1000000;
        $fatal(1, "TIMEOUT");
    end
endmodule
