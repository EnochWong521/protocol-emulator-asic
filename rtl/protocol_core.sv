// Instruction memory must provide a combinational read: inst = memory[inst_addr].
// GPIO output buffers belong outside the core; enable=1 drives the stored value.
module protocol_core (
    input  logic       clk,
    input  logic       reset,
    input  logic [7:0] inst,
    output logic [7:0] inst_addr,
    input  logic [3:0] gpio_in_async,
    output logic [3:0] gpio_out_value,
    output logic [3:0] gpio_out_enable,
    output logic       timing_overrun // Sticky until reset: a WAIT interval was missed.
);
    import isa_pkg::*;

    logic [7:0] pc_value, ir, imm;
    logic ir_load, imm_load;
    logic [1:0] pc_sel;
    logic wait_c_write, wait_start, wait_tick;
    logic wait_rebase;
    logic [1:0] wait_mode;
    logic [T_WIDTH-1:0] t_write_data;
    logic wait_c_nonzero, wait_is_single_cycle, wait_is_last_cycle;
    logic direction, reg_sel;
    logic exec_shift_in, exec_shift_out, exec_mov_imm, exec_mov_reg;
    logic exec_cmp_imm, exec_cmp_reg;
    logic [1:0] pin_sel, shift_out_mode, cmp_op;
    logic [3:0] gpio_in_sync;
    logic gpio_sync_valid, cmp_flag;
    logic [7:0] r0_data, r1_data;

    assign t_write_data = {ir[WAIT_C_T_UPPER_MSB:WAIT_C_T_UPPER_LSB], imm};
    assign wait_c_nonzero = |t_write_data;

    pc u_pc (
        .clk(clk), .reset(reset), .pc_sel(pc_sel),
        .pc_target(imm), .pc(pc_value)
    );

    inst_fetch u_fetch (
        .clk(clk), .reset(reset), .pc_value(pc_value), .inst(inst),
        .ir_load(ir_load), .imm_load(imm_load),
        .inst_addr(inst_addr), .ir(ir), .imm(imm)
    );

    control_unit u_control (
        .clk(clk), .reset(reset), .inst(inst), .ir(ir),
        .wait_c_nonzero(wait_c_nonzero),
        .wait_is_single_cycle(wait_is_single_cycle),
        .wait_is_last_cycle(wait_is_last_cycle),
        .gpio_in_sync(gpio_in_sync), .gpio_sync_valid(gpio_sync_valid),
        .cmp_flag(cmp_flag), .ir_load(ir_load), .imm_load(imm_load),
        .wait_start(wait_start), .wait_c_write(wait_c_write),
        .wait_rebase(wait_rebase),
        .wait_mode(wait_mode), .wait_tick(wait_tick), .pc_sel(pc_sel),
        .direction(direction), .exec_shift_in(exec_shift_in),
        .exec_shift_out(exec_shift_out), .exec_mov_imm(exec_mov_imm),
        .exec_mov_reg(exec_mov_reg), .exec_cmp_imm(exec_cmp_imm),
        .exec_cmp_reg(exec_cmp_reg), .reg_sel(reg_sel), .pin_sel(pin_sel),
        .shift_out_mode(shift_out_mode), .cmp_op(cmp_op)
    );

    wait_timer u_timer (
        .clk(clk), .rst(reset), .wait_c_write(wait_c_write),
        .t_write_data(t_write_data), .wait_start(wait_start),
        .wait_rebase(wait_rebase),
        .wait_mode(wait_mode), .wait_tick(wait_tick),
        .timing_overrun(timing_overrun),
        .wait_is_single_cycle(wait_is_single_cycle),
        .wait_is_last_cycle(wait_is_last_cycle)
    );

    // shift_datapath owns the single shared R0/R1 register bank.
    shift_datapath u_shift (
        .clk(clk), .rst(reset), .exec_shift_in(exec_shift_in),
        .exec_shift_out(exec_shift_out), .exec_mov_imm(exec_mov_imm),
        .exec_mov_reg(exec_mov_reg), .reg_sel(reg_sel), .pin_sel(pin_sel),
        .shift_out_mode(shift_out_mode), .shift_dir(direction), .imm_data(imm),
        .gpio_in_async(gpio_in_async), .gpio_in_sync(gpio_in_sync),
        .gpio_sync_valid(gpio_sync_valid), .gpio_out_value(gpio_out_value),
        .gpio_out_enable(gpio_out_enable), .r0_data(r0_data), .r1_data(r1_data)
    );

    cmp_datapath u_compare (
        .clk(clk), .rst(reset), .exec_cmp_imm(exec_cmp_imm),
        .exec_cmp_reg(exec_cmp_reg), .reg_sel(reg_sel), .cmp_op(cmp_op),
        .imm_data(imm), .r0_data(r0_data), .r1_data(r1_data), .cmp_flag(cmp_flag)
    );
endmodule
