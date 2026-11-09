module control_unit (
    input   logic [7:0]   inst,
    input   logic [7:0]   ir,
    input   logic         wait_c_nonzero,
    input   logic         clk,
    input   logic         reset,
    input   logic         wait_is_single_cycle,
    input   logic         wait_is_last_cycle,
    input   logic [3:0]   gpio_in_sync, // Shared shift_datapath synchronizer output.
    input   logic         gpio_sync_valid,
    input   logic         cmp_flag,     // Persistent cmp_datapath result.

    output  logic         ir_load,
    output  logic         imm_load,
    output  logic         wait_start,
    output  logic         wait_c_write,
    output  logic [1:0]   wait_mode,
    output  logic         wait_tick,
    output  logic [1:0]   pc_sel,
    output  logic         direction,
    output  logic         exec_shift_in,
    output  logic         exec_shift_out,
    output  logic         exec_mov_imm,
    output  logic         exec_mov_reg,
    output  logic         exec_cmp_imm,
    output  logic         exec_cmp_reg,
    output  logic         reg_sel,
    output  logic [1:0]   pin_sel,
    output  logic [1:0]   shift_out_mode,
    output  logic [1:0]   cmp_op
);

    import isa_pkg::*;

    typedef enum logic [1:0] {
        FETCH         = 2'b00,
        FETCH_OPERAND = 2'b01,
        EXECUTE       = 2'b10,
        WAIT_REMAIN   = 2'b11
    } state_t;

    state_t state, next_state;
    logic inst_two_byte;
    logic loop_active, next_loop_active;
    logic [4:0] loop_remaining, next_loop_remaining;
    logic edge_armed, next_edge_armed;
    logic edge_prev, next_edge_prev;
    logic selected_pin_sync;
    logic branch_taken, branch_legal;

    // PIN_CTRL uses IR[4:3], unlike the SHIFT pin field at IR[3:2].
    assign selected_pin_sync = gpio_in_sync[ir[PIN_CTRL_PIN_MSB:PIN_CTRL_PIN_LSB]];

    // Length predecode uses the current fetch byte, independently of legality.
    always_comb begin
        case (inst[OPCODE_MSB:OPCODE_LSB])
            OP_WAIT_C, OP_LOOP:
                inst_two_byte = 1'b1;

            OP_PIN_CTRL:
                inst_two_byte =
                    (inst[PIN_CTRL_MODE_BIT] == PIN_BRANCH_MODE);

            OP_MOVE:
                inst_two_byte =
                    (inst[MOVE_SUBMODE_MSB:MOVE_SUBMODE_LSB] == MOV_IMM) ||
                    (inst[MOVE_SUBMODE_MSB:MOVE_SUBMODE_LSB] == CMP_IMM);

            default:
                inst_two_byte = 1'b0;
        endcase
    end

    assign ir_load = !reset && (state == FETCH);
    assign imm_load = !reset && (state == FETCH_OPERAND);
    assign wait_mode = ir[WAIT_SUBMODE_MSB:WAIT_SUBMODE_LSB];

    // SHIFT and MOVE/CMP share the register-select field at IR[4].
    assign reg_sel = ir[SHIFT_IN_REG_BIT];
    assign pin_sel = ir[SHIFT_IN_PIN_MSB:SHIFT_IN_PIN_LSB];
    assign shift_out_mode = ir[SHIFT_OUT_MODE_MSB:SHIFT_OUT_MODE_LSB];
    assign cmp_op = ir[CMP_OP_MSB:CMP_OP_LSB];

    always_ff @(posedge clk) begin
        if (reset == 1) begin
            state <= FETCH;
            direction <= DIR_RIGHT;
            loop_active <= 1'b0;
            loop_remaining <= 5'd0;
            edge_armed <= 1'b0;
            edge_prev <= 1'b0;
        end
        else begin
            state <= next_state;
            loop_active <= next_loop_active;
            loop_remaining <= next_loop_remaining;
            edge_armed <= next_edge_armed;
            edge_prev <= next_edge_prev;
            // Register the direction only for a legal SET_DIR.
            if(state == EXECUTE &&
               ir[OPCODE_MSB:OPCODE_LSB] == OP_WAIT &&
               ir[WAIT_SUBMODE_MSB:WAIT_SUBMODE_LSB] == SET_DIR &&
               ir[SET_DIR_RSVD_MSB:SET_DIR_RSVD_LSB] == SET_DIR_RSVD_REQUIRED) begin
                direction <= ir[SET_DIR_DIRECTION_BIT];
            end
        end
    end

    always_comb begin
        next_state = state;
        next_loop_active = loop_active;
        next_loop_remaining = loop_remaining;
        next_edge_armed = edge_armed;
        next_edge_prev = edge_prev;
        branch_taken = 1'b0;
        branch_legal = 1'b0;

        wait_start = 1'b0;
        wait_c_write = 1'b0;
        wait_tick = 1'b0;
        exec_shift_in = 1'b0;
        exec_shift_out = 1'b0;
        exec_mov_imm = 1'b0;
        exec_mov_reg = 1'b0;
        exec_cmp_imm = 1'b0;
        exec_cmp_reg = 1'b0;
        pc_sel = PC_HOLD;

        if (!reset) begin
            case(state)

                FETCH: begin
                    if (inst_two_byte)
                        next_state = FETCH_OPERAND;
                    else
                        next_state = EXECUTE;
                end

                FETCH_OPERAND: begin
                    next_state = EXECUTE;
                end

                EXECUTE: begin

                    //WAIT_C
                    if(ir[OPCODE_MSB:OPCODE_LSB] == OP_WAIT_C) begin
                        if (wait_c_nonzero) begin
                            wait_c_write = 1'b1;
                            pc_sel = PC_PLUS_2;
                            next_state = FETCH;
                        end
                    end

                    //WAIT / SET_DIR
                    else if(ir[OPCODE_MSB:OPCODE_LSB] == OP_WAIT) begin

                        //SET_DIR
                        if(ir[WAIT_SUBMODE_MSB:WAIT_SUBMODE_LSB] == SET_DIR &&
                           ir[SET_DIR_RSVD_MSB:SET_DIR_RSVD_LSB] == SET_DIR_RSVD_REQUIRED) begin
                            pc_sel = PC_PLUS_1;
                            next_state = FETCH;
                        end

                        //WAIT
                        else if(ir[WAIT_SUBMODE_MSB:WAIT_SUBMODE_LSB] != SET_DIR &&
                                ir[WAIT_ARG_MSB:WAIT_ARG_LSB] == WAIT_ARG_REQUIRED) begin
                            wait_start = 1'b1;
                            if(wait_is_single_cycle) begin
                                pc_sel = PC_PLUS_1;
                                next_state = FETCH;
                            end
                            else begin
                                next_state = WAIT_REMAIN;
                            end
                        end
                    end
                    else if (ir[OPCODE_MSB:OPCODE_LSB] == OP_LOOP) begin
                        // The body has already run once. Zero encodes 32 total passes.
                        next_state = FETCH;
                        if (!loop_active) begin
                            if (ir[LOOP_COUNT_MSB:LOOP_COUNT_LSB] == 5'd1) begin
                                next_loop_active = 1'b0;
                                next_loop_remaining = 5'd0;
                                pc_sel = PC_PLUS_2;
                            end
                            else begin
                                next_loop_active = 1'b1;
                                next_loop_remaining =
                                    (ir[LOOP_COUNT_MSB:LOOP_COUNT_LSB] == LOOP_COUNT_32_ENCODING)
                                    ? 5'd31 : ir[LOOP_COUNT_MSB:LOOP_COUNT_LSB] - 5'd1;
                                pc_sel = PC_TARGET;
                            end
                        end
                        else if (loop_remaining > 5'd1) begin
                            next_loop_remaining = loop_remaining - 5'd1;
                            pc_sel = PC_TARGET;
                        end
                        else begin
                            next_loop_active = 1'b0;
                            next_loop_remaining = 5'd0;
                            pc_sel = PC_PLUS_2;
                        end
                    end
                    else if (ir[OPCODE_MSB:OPCODE_LSB] == OP_PIN_CTRL) begin
                        if (ir[PIN_CTRL_MODE_BIT] == PIN_WAIT_MODE && gpio_sync_valid) begin
                            case (ir[PIN_CTRL_COND_MSB:PIN_CTRL_COND_LSB])
                                PIN_WAIT_LOW, PIN_WAIT_HIGH: begin
                                    if (selected_pin_sync ==
                                        (ir[PIN_CTRL_COND_MSB:PIN_CTRL_COND_LSB] == PIN_WAIT_HIGH)) begin
                                        pc_sel = PC_PLUS_1;
                                        next_state = FETCH;
                                        next_edge_armed = 1'b0;
                                    end
                                end

                                PIN_WAIT_RISING, PIN_WAIT_FALLING: begin
                                    // First valid EXECUTE sample establishes a baseline only.
                                    next_edge_prev = selected_pin_sync;
                                    if (!edge_armed) begin
                                        next_edge_armed = 1'b1;
                                    end
                                    else if ((ir[PIN_CTRL_COND_MSB:PIN_CTRL_COND_LSB] == PIN_WAIT_RISING &&
                                              !edge_prev && selected_pin_sync) ||
                                             (ir[PIN_CTRL_COND_MSB:PIN_CTRL_COND_LSB] == PIN_WAIT_FALLING &&
                                              edge_prev && !selected_pin_sync)) begin
                                        pc_sel = PC_PLUS_1;
                                        next_state = FETCH;
                                        next_edge_armed = 1'b0;
                                    end
                                end

                                default: begin end
                            endcase
                        end
                        else if (ir[PIN_CTRL_MODE_BIT] == PIN_BRANCH_MODE) begin
                            case (ir[PIN_CTRL_COND_MSB:PIN_CTRL_COND_LSB])
                                PIN_BR_LOW: begin
                                    branch_legal = gpio_sync_valid;
                                    branch_taken = !selected_pin_sync;
                                end
                                PIN_BR_HIGH: begin
                                    branch_legal = gpio_sync_valid;
                                    branch_taken = selected_pin_sync;
                                end
                                PIN_BR_JMP: begin
                                    branch_legal = 1'b1;
                                    branch_taken = 1'b1;
                                end
                                PIN_BR_FLAG: begin
                                    if (ir[PIN_CTRL_FLAG_RSVD_BIT] == PIN_CTRL_FLAG_RSVD_REQUIRED) begin
                                        branch_legal = 1'b1;
                                        branch_taken = (ir[PIN_CTRL_FLAG_SENSE_BIT] == BR_FLAG_TRUE)
                                                     ? cmp_flag : !cmp_flag;
                                    end
                                end
                                default: begin end
                            endcase

                            if (branch_legal) begin
                                pc_sel = branch_taken ? PC_TARGET : PC_PLUS_2;
                                next_state = FETCH;
                                if (branch_taken) begin
                                    next_loop_active = 1'b0;
                                    next_loop_remaining = 5'd0;
                                end
                            end
                        end
                    end
                    else if (ir[OPCODE_MSB:OPCODE_LSB] == OP_SHIFT_IN) begin
                        if (ir[SHIFT_IN_RSVD_MSB:SHIFT_IN_RSVD_LSB] == SHIFT_IN_RSVD_REQUIRED &&
                            gpio_sync_valid) begin
                            exec_shift_in = 1'b1;
                            pc_sel = PC_PLUS_1;
                            next_state = FETCH;
                        end
                    end
                    else if (ir[OPCODE_MSB:OPCODE_LSB] == OP_SHIFT_OUT) begin
                        exec_shift_out = 1'b1;
                        pc_sel = PC_PLUS_1;
                        next_state = FETCH;
                    end
                    else if (ir[OPCODE_MSB:OPCODE_LSB] == OP_MOVE) begin
                        case (ir[MOVE_SUBMODE_MSB:MOVE_SUBMODE_LSB])
                            MOV_IMM, MOV_REG: begin
                                if (ir[MOVE_LOW_MSB:MOVE_LOW_LSB] == MOV_LOW_REQUIRED) begin
                                    exec_mov_imm =
                                        (ir[MOVE_SUBMODE_MSB:MOVE_SUBMODE_LSB] == MOV_IMM);
                                    exec_mov_reg =
                                        (ir[MOVE_SUBMODE_MSB:MOVE_SUBMODE_LSB] == MOV_REG);
                                    pc_sel = exec_mov_imm ? PC_PLUS_2 : PC_PLUS_1;
                                    next_state = FETCH;
                                end
                            end

                            CMP_IMM, CMP_REG: begin
                                case (ir[CMP_OP_MSB:CMP_OP_LSB])
                                    CMP_EQ, CMP_LT, CMP_GT: begin
                                        exec_cmp_imm =
                                            (ir[MOVE_SUBMODE_MSB:MOVE_SUBMODE_LSB] == CMP_IMM);
                                        exec_cmp_reg =
                                            (ir[MOVE_SUBMODE_MSB:MOVE_SUBMODE_LSB] == CMP_REG);
                                        pc_sel = exec_cmp_imm ? PC_PLUS_2 : PC_PLUS_1;
                                        next_state = FETCH;
                                    end

                                    default: begin end
                                endcase
                            end

                            default: begin end
                        endcase
                    end
                end

                WAIT_REMAIN: begin
                    wait_tick = 1'b1;
                    if(wait_is_last_cycle) begin
                        pc_sel = PC_PLUS_1;
                        next_state = FETCH;
                    end
                end

                default: next_state = FETCH;
            endcase
        end
    end
endmodule
