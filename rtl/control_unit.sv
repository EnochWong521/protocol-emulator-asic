module control_unit (
    input   logic [7:0]   inst,
    input   logic [7:0]   ir,
    input   logic         wait_c_nonzero,
    input   logic         clk,
    input   logic         reset,
    input   logic         wait_is_single_cycle,
    input   logic         wait_is_last_cycle,

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
        end
        else begin
            state <= next_state;
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
                    else if (ir[OPCODE_MSB:OPCODE_LSB] == OP_SHIFT_IN) begin
                        if (ir[SHIFT_IN_RSVD_MSB:SHIFT_IN_RSVD_LSB] == SHIFT_IN_RSVD_REQUIRED) begin
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
