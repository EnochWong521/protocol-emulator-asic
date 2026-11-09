`timescale 1ns/1ps

// Startup regression using the real synchronizer, controller, fetch and PC.
// No production processor top-level is required.
module tb_gpio_sync_startup;
    import isa_pkg::*;

    logic clk = 0, reset = 1;
    logic [3:0] gpio_in_async = 0;
    logic [7:0] memory [0:255];
    wire [7:0] pc_value, inst_addr, ir, imm;
    wire [7:0] inst = memory[inst_addr];
    wire ir_load, imm_load, direction, reg_sel;
    wire exec_shift_in, exec_shift_out, exec_mov_imm, exec_mov_reg;
    wire [1:0] pc_sel, pin_sel, shift_out_mode;
    wire [3:0] gpio_in_sync;
    wire gpio_sync_valid;
    wire [7:0] r0_data, r1_data;
    int cases = 0;

    always #5 clk = ~clk;

    pc u_pc (.clk(clk), .reset(reset), .pc_sel(pc_sel),
             .pc_target(imm), .pc(pc_value));
    inst_fetch u_fetch (
        .clk(clk), .reset(reset), .pc_value(pc_value), .inst(inst),
        .ir_load(ir_load), .imm_load(imm_load), .inst_addr(inst_addr),
        .ir(ir), .imm(imm)
    );
    control_unit ctrl (
        .clk(clk), .reset(reset), .inst(inst), .ir(ir),
        .wait_c_nonzero(1'b1), .wait_is_single_cycle(1'b1),
        .wait_is_last_cycle(1'b0), .cmp_flag(1'b0),
        .gpio_in_sync(gpio_in_sync), .gpio_sync_valid(gpio_sync_valid),
        .ir_load(ir_load), .imm_load(imm_load), .pc_sel(pc_sel),
        .direction(direction), .reg_sel(reg_sel), .pin_sel(pin_sel),
        .shift_out_mode(shift_out_mode), .exec_shift_in(exec_shift_in),
        .exec_shift_out(exec_shift_out), .exec_mov_imm(exec_mov_imm),
        .exec_mov_reg(exec_mov_reg)
    );
    shift_datapath datapath (
        .clk(clk), .rst(reset), .exec_shift_in(exec_shift_in),
        .exec_shift_out(exec_shift_out), .exec_mov_imm(exec_mov_imm),
        .exec_mov_reg(exec_mov_reg), .reg_sel(reg_sel), .pin_sel(pin_sel),
        .shift_out_mode(shift_out_mode), .shift_dir(direction), .imm_data(imm),
        .gpio_in_async(gpio_in_async), .gpio_in_sync(gpio_in_sync),
        .gpio_sync_valid(gpio_sync_valid), .r0_data(r0_data), .r1_data(r1_data)
    );

    task automatic tick(input logic [7:0] expected_pc,
                        input logic expected_valid);
        @(posedge clk); #1;
        if (pc_value !== expected_pc || gpio_sync_valid !== expected_valid)
            $fatal(1, "PC=%h expected=%h valid=%b expected=%b IR=%h",
                   pc_value, expected_pc, gpio_sync_valid, expected_valid, ir);
        @(negedge clk);
    endtask

    task automatic start_case(input logic [7:0] opcode,
                              input logic [3:0] pins);
        reset = 1;
        gpio_in_async = pins;
        for (int i = 0; i < 256; i++) memory[i] = 8'hFF; // Unsupported DATA_IO.
        memory[0] = opcode;
        tick(0, 0);
        if (ctrl.edge_armed !== 0 || r0_data !== 0 || r1_data !== 0)
            $fatal(1, "reset did not clear pin wait/register state");
        reset = 0;
        tick(0, 0); // First-stage sample only; instruction has been fetched.
        if (exec_shift_in !== 0 || ctrl.edge_armed !== 0)
            $fatal(1, "pin instruction acted before the synchronizer filled");
        tick(0, 1); // Second stage fills; no instruction can use it on this edge.
        if (ctrl.edge_armed !== 0 || r0_data !== 0 || r1_data !== 0 || ir !== opcode)
            $fatal(1, "pin instruction changed state during synchronizer startup");
    endtask

    initial begin
        logic [3:0] pins;
        logic [7:0] opcode;
        @(negedge clk);
        for (int pin = 0; pin < 4; pin++) begin
            for (int mode = 0; mode < 4; mode++) begin
                // LOW starts high; HIGH starts high; RISING starts high;
                // FALLING starts low. Other pins have the opposite level.
                pins = mode == 3 ? ~(4'b0001 << pin) : (4'b0001 << pin);
                opcode = 8'h41 | (8'(pin) << 3) | (8'(mode) << 1);
                start_case(opcode, pins);
                if (mode == 1) begin
                    tick(1, 1); // HIGH finishes on the first valid execution edge.
                end
                else begin
                    repeat (3) tick(0, 1); // Constant input must not finish the wait.
                    if (mode >= 2 && ctrl.edge_armed !== 1)
                        $fatal(1, "edge wait did not arm on a valid sample");
                    gpio_in_async[pin] = !pins[pin];
                    if (mode >= 2) begin
                        // First transition is opposite to the requested edge.
                        repeat (3) tick(0, 1);
                        gpio_in_async[pin] = pins[pin];
                    end
                    tick(0, 1); // Transition enters first synchronizer stage.
                    tick(0, 1); // Transition enters second stage.
                    tick(1, 1); // Requested condition retires exactly once.
                end
                if (ctrl.edge_armed !== 0)
                    $fatal(1, "WAIT_PIN retirement did not clear arming state");
                tick(1, 1); // Fetch unsupported instruction.
                tick(1, 1); // It stalls; no repeated retirement.
                cases++;
            end

            // A first-instruction SHIFT_IN must sample high, not reset zero.
            for (int selected = 0; selected < 2; selected++) begin
                opcode = 8'h80 | (8'(selected) << 4) | (8'(pin) << 2);
                start_case(opcode, 4'b0001 << pin);
                tick(1, 1);
                if (r0_data !== (selected == 0 ? 8'h80 : 8'h00) ||
                    r1_data !== (selected == 1 ? 8'h80 : 8'h00))
                    $fatal(1, "SHIFT_IN sampled a reset value or wrong register");
                tick(1, 1);
                tick(1, 1);
                if (r0_data !== (selected == 0 ? 8'h80 : 8'h00) ||
                    r1_data !== (selected == 1 ? 8'h80 : 8'h00))
                    $fatal(1, "SHIFT_IN wrote more than once");
                cases++;
            end
        end
        $display("PASS: %0d GPIO startup cases, all pins/wait modes, both registers, repeated resets", cases);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "GPIO startup regression timed out");
    end
endmodule
