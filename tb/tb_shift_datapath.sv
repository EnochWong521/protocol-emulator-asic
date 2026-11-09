`timescale 1ns/1ps

// iverilog -g2012 -s tb_shift_datapath -o /tmp/tb_shift_datapath.vvp \
//   rtl/isa_pkg.sv rtl/register_file.sv rtl/shift_datapath.sv tb/tb_shift_datapath.sv
// vvp /tmp/tb_shift_datapath.vvp [+vcd]
module tb_shift_datapath;
    import isa_pkg::*;
    localparam logic [3:0] IDLE = 4'b0000, SHIFT_IN = 4'b1000,
                           SHIFT_OUT = 4'b0100, MOVE_IMM = 4'b0010, MOVE_REG = 4'b0001;
    localparam logic [7:0] PATTERN = 8'h96; // Bit reversal differs: 69.
    logic clk = 0;
    logic rst = 1;
    logic [3:0] commands = IDLE;
    logic reg_sel = REG_R0;
    logic [1:0] pin_sel = PIN_P0;
    logic [1:0] shift_out_mode = SHIFT_OUT_LOW;
    logic shift_dir = DIR_RIGHT;
    logic [7:0] imm_data = 0;
    logic [3:0] gpio_in_async = 0;
    wire [3:0] gpio_in_sync, gpio_out_value, gpio_out_enable;
    wire [7:0] r0_data, r1_data;
    logic [3:0] reference_sync1 = 0, reference_sync2 = 0;
    int checked_cycles = 0;
    int shift_in_cases = 0, shift_out_cases = 0, fixed_output_cases = 0;

    always #5 clk = ~clk;
    shift_datapath dut (
        .clk(clk), .rst(rst),
        .exec_shift_in(commands[3]), .exec_shift_out(commands[2]),
        .exec_mov_imm(commands[1]), .exec_mov_reg(commands[0]),
        .reg_sel(reg_sel), .pin_sel(pin_sel), .shift_out_mode(shift_out_mode),
        .shift_dir(shift_dir), .imm_data(imm_data), .gpio_in_async(gpio_in_async),
        .gpio_in_sync(gpio_in_sync), .gpio_out_value(gpio_out_value),
        .gpio_out_enable(gpio_out_enable), .r0_data(r0_data), .r1_data(r1_data)
    );

    // Conflicting/unknown commands are test failures, not hardware arbitration.
    always @(posedge clk) begin
        if (!rst && ($isunknown(commands) || !$onehot0(commands)))
            $fatal(1, "datapath execution commands must be one-hot or zero");
    end

    task automatic step(input logic [3:0] command,
                        input logic selection,
                        input logic [1:0] pin, mode,
                        input logic direction,
                        input logic [7:0] immediate,
                        input logic [3:0] raw_input,
                        input logic [7:0] expected_r0, expected_r1,
                        input logic [3:0] expected_value, expected_enable,
                        input logic reset_value = 0);
        logic [27:0] previous_outputs;
        @(negedge clk);
        previous_outputs = {r0_data, r1_data, gpio_out_value, gpio_out_enable, gpio_in_sync};
        rst = reset_value;
        commands = command;
        reg_sel = selection;
        pin_sel = pin;
        shift_out_mode = mode;
        shift_dir = direction;
        imm_data = immediate;
        gpio_in_async = raw_input;
        #1;
        if ({r0_data, r1_data, gpio_out_value, gpio_out_enable, gpio_in_sync} !== previous_outputs)
            $fatal(1, "datapath state changed before rising edge");
        @(posedge clk);
        if (reset_value) begin
            reference_sync1 = 0;
            reference_sync2 = 0;
        end
        else begin
            reference_sync2 = reference_sync1;
            reference_sync1 = raw_input;
        end
        #1;
        if ({r0_data, r1_data, gpio_out_value, gpio_out_enable, gpio_in_sync} !==
            {expected_r0, expected_r1, expected_value, expected_enable, reference_sync2})
            $fatal(1, "command=%b sel=%b pin=%d dir=%b: R0/R1=%h/%h expected=%h/%h GPIO=%h/%h expected=%h/%h sync=%h expected=%h",
                   commands, reg_sel, pin_sel, shift_dir, r0_data, r1_data,
                   expected_r0, expected_r1, gpio_out_value, gpio_out_enable,
                   expected_value, expected_enable, gpio_in_sync, reference_sync2);
        checked_cycles++;
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("shift_datapath.vcd");
            $dumpvars(0, tb_shift_datapath);
        end
    end

    initial begin
        logic [7:0] expected_reg, expected_r0, expected_r1;
        logic [3:0] raw_input, expected_value, expected_enable;
        logic sample;
        @(posedge clk); #1;
        if ({r0_data, r1_data, gpio_out_value, gpio_out_enable, gpio_in_sync} !== 28'd0)
            $fatal(1, "initial reset failed");
        checked_cycles++;

        // MOV_IMM to both destinations and MOV_REG in both directions.
        step(MOVE_IMM, REG_R0, 0, 0, 0, 8'hA5, 0, 8'hA5, 0, 0, 0);
        step(MOVE_IMM, REG_R1, 0, 0, 0, 8'h3C, 0, 8'hA5, 8'h3C, 0, 0);
        step(MOVE_REG, REG_R0, 0, 0, 0, 8'hFF, 0, 8'h3C, 8'h3C, 0, 0);
        step(MOVE_IMM, REG_R0, 0, 0, 0, 8'h96, 0, 8'h96, 8'h3C, 0, 0);
        step(MOVE_REG, REG_R1, 0, 0, 0, 8'h00, 0, 8'h96, 8'h96, 0, 0);

        // A fresh input cannot bypass the synchronizer. The second-edge
        // SHIFT_IN sees the OLD stage two, even as stage two changes to one.
        step(MOVE_IMM, REG_R0, 0, 0, 0, 0, 0, 0, 8'h96, 0, 0);
        step(IDLE, REG_R0, 0, 0, 0, 0, 1, 0, 8'h96, 0, 0);
        step(SHIFT_IN, REG_R0, 0, 0, DIR_RIGHT, 0, 1, 0, 8'h96, 0, 0);
        step(SHIFT_IN, REG_R0, 0, 0, DIR_RIGHT, 0, 0, 8'h80, 8'h96, 0, 0);
        step(SHIFT_IN, REG_R0, 0, 0, DIR_RIGHT, 0, 0, 8'hC0, 8'h96, 0, 0);
        step(SHIFT_IN, REG_R0, 0, 0, DIR_RIGHT, 0, 0, 8'h60, 8'h96, 0, 0);

        // Seed persistent pin state; every subsequent command checks all pins.
        expected_value = 0;
        expected_enable = 0;
        for (int pin = 0; pin < 4; pin++) begin
            expected_value[pin] = pin[0];
            expected_enable[pin] = 1;
            step(SHIFT_OUT, REG_R0, pin[1:0], pin[0] ? SHIFT_OUT_HIGH : SHIFT_OUT_LOW,
                 DIR_RIGHT, 0, 0, 8'h60, 8'h96, expected_value, expected_enable);
        end

        for (int direction = 0; direction < 2; direction++) begin
            for (int selected = 0; selected < 2; selected++) begin
                for (int pin = 0; pin < 4; pin++) begin
                    // Sentinel in the unselected register must survive all eight shifts.
                    step(MOVE_IMM, REG_R0, 0, 0, 0, selected[0] ? 8'h3C : 0,
                         0, selected[0] ? 8'h3C : 0, 8'h96, expected_value, expected_enable);
                    step(MOVE_IMM, REG_R1, 0, 0, 0, selected[0] ? 0 : 8'h3C,
                         0, selected[0] ? 8'h3C : 0, selected[0] ? 0 : 8'h3C,
                         expected_value, expected_enable);
                    expected_reg = 0;
                    for (int bit_index = 0; bit_index < 8; bit_index++) begin
                        sample = direction[0] == DIR_RIGHT ? PATTERN[bit_index] : PATTERN[7-bit_index];
                        raw_input = 4'b1010;
                        raw_input[pin] = sample;
                        expected_r0 = selected[0] ? 8'h3C : expected_reg;
                        expected_r1 = selected[0] ? expected_reg : 8'h3C;
                        // Two idle edges settle the new input; execute samples on edge three.
                        repeat (2) step(IDLE, selected[0], pin[1:0], 0, direction[0], 8'hFF,
                                        raw_input, expected_r0, expected_r1, expected_value, expected_enable);
                        if (direction[0] == DIR_RIGHT)
                            expected_reg = REG_WIDTH'((int'(PATTERN) % (1 << (bit_index+1))) << (7-bit_index));
                        else
                            expected_reg = PATTERN >> (7-bit_index);
                        step(SHIFT_IN, selected[0], pin[1:0], 0, direction[0], 8'hFF, raw_input,
                             selected[0] ? 8'h3C : expected_reg, selected[0] ? expected_reg : 8'h3C,
                             expected_value, expected_enable);
                    end
                    if (expected_reg !== PATTERN) $fatal(1, "bad SHIFT_IN reference byte");
                    shift_in_cases++;
                    // Restore a known pair for the next test case.
                    step(MOVE_IMM, REG_R1, 0, 0, 0, 8'h96, 0,
                         selected[0] ? 8'h3C : PATTERN, 8'h96, expected_value, expected_enable);
                end
            end
        end

        step(MOVE_IMM, REG_R0, 0, 0, 0, PATTERN, 0, PATTERN, 8'h96, expected_value, expected_enable);
        step(MOVE_IMM, REG_R1, 0, 0, 0, 8'h3C, 0, PATTERN, 8'h3C, expected_value, expected_enable);
        for (int direction = 0; direction < 2; direction++) begin
            for (int selected = 0; selected < 2; selected++) begin
                for (int pin = 0; pin < 4; pin++) begin
                    for (int mode = 0; mode < 3; mode++) begin
                        if (mode[1:0] == SHIFT_OUT_RELEASE)
                            expected_enable[pin] = 0;
                        else begin
                            expected_value[pin] = (mode[1:0] == SHIFT_OUT_HIGH);
                            expected_enable[pin] = 1;
                        end
                        step(SHIFT_OUT, selected[0], pin[1:0], mode[1:0], direction[0], 8'hFF,
                             4'hF, PATTERN, 8'h3C, expected_value, expected_enable);
                        fixed_output_cases++;
                    end
                end
            end
        end

        for (int direction = 0; direction < 2; direction++) begin
            for (int selected = 0; selected < 2; selected++) begin
                for (int pin = 0; pin < 4; pin++) begin
                    step(MOVE_IMM, REG_R0, 0, 0, 0, selected[0] ? 8'h3C : PATTERN,
                         0, selected[0] ? 8'h3C : PATTERN, 8'h3C, expected_value, expected_enable);
                    step(MOVE_IMM, REG_R1, 0, 0, 0, selected[0] ? PATTERN : 8'h3C,
                         0, selected[0] ? 8'h3C : PATTERN, selected[0] ? PATTERN : 8'h3C,
                         expected_value, expected_enable);
                    for (int bit_index = 0; bit_index < 8; bit_index++) begin
                        expected_value[pin] = direction[0] == DIR_RIGHT ? PATTERN[bit_index] : PATTERN[7-bit_index];
                        expected_enable[pin] = 1;
                        expected_reg = direction[0] == DIR_RIGHT ? PATTERN >> (bit_index+1)
                                                                               : REG_WIDTH'(int'(PATTERN) << (bit_index+1));
                        step(SHIFT_OUT, selected[0], pin[1:0], SHIFT_OUT_SHIFT, direction[0], 8'hFF,
                             4'hF, selected[0] ? 8'h3C : expected_reg, selected[0] ? expected_reg : 8'h3C,
                             expected_value, expected_enable);
                    end
                    shift_out_cases++;
                    step(MOVE_IMM, REG_R1, 0, 0, 0, 8'h3C, 0,
                         selected[0] ? 8'h3C : 0, 8'h3C, expected_value, expected_enable);
                end
            end
        end

        // Idle retention with changing selectors/data and nonzero GPIO state.
        repeat (3) step(IDLE, REG_R1, PIN_P3, SHIFT_OUT_SHIFT, DIR_LEFT, 8'hFF,
                        4'hF, 8'h3C, 8'h3C, expected_value, expected_enable);
        // Reset overrides both register-writing and GPIO-writing commands.
        step(SHIFT_OUT, REG_R0, PIN_P0, SHIFT_OUT_SHIFT, DIR_RIGHT, 8'hFF, 4'hF, 0, 0, 0, 0, 1);
        step(MOVE_IMM, REG_R1, PIN_P1, SHIFT_OUT_HIGH, DIR_LEFT, 8'hFF, 4'hF, 0, 0, 0, 0, 1);
        step(IDLE, REG_R0, PIN_P0, SHIFT_OUT_LOW, DIR_RIGHT, 0, 0, 0, 0, 0, 0);
        if (shift_in_cases != 16 || shift_out_cases != 16 || fixed_output_cases != 48)
            $fatal(1, "shift/pin coverage incomplete");
        $display("PASS: MOVE both destinations/sources; %0d SHIFT_IN bytes, %0d SHIFT_OUT bytes, %0d fixed-output cases",
                 shift_in_cases, shift_out_cases, fixed_output_cases);
        $display("PASS: synchronizer latency, old endpoint, GPIO retention, reset and edge timing; %0d checks",
                 checked_cycles);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "shift datapath test timeout");
    end
endmodule
