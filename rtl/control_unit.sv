module control_unit (
    input   logic [7:0]   inst,
    input   logic [7:0]   pc_value,
    input   logic         clk,
    input   logic         reset,
    input   logic         wait_done,

    output  logic         wait_start,
    output  logic         wait_config_U,
    output  logic         wait_config_L,
    output  logic [1:0]   pc_sel,
    output  logic [7:0]   inst_addr,
    output  logic         direction
);

    import isa_pkg::*;

    typedef enum logic [1:0] {
        FETCH         = 2'b00,
        FETCH_OPERAND = 2'b01,
        EXECUTE       = 2'b10,
        WAIT_REMAIN   = 2'b11
    } state_t;

    state_t state, next_state;
    logic [INST_WIDTH-1:0] ir;
    logic [INST_WIDTH-1:0] imm;
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

    assign inst_addr = (state == FETCH_OPERAND)
                      ? pc_value + PC_WIDTH'(ONE_BYTE)
                      : pc_value;

    always_ff @(posedge clk) begin
        if (reset == 1) begin
            state <= FETCH;
            ir <= '0;
            imm <= '0;
            direction <= DIR_RIGHT;
        end
        else begin
            state <= next_state;
            // Capture the first byte, or the optional second byte.
            if(state == FETCH) begin
                ir <= inst;
            end
            else if(state == FETCH_OPERAND) begin
                imm <= inst;
            end

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
        wait_config_U = 1'b0;
        wait_config_L = 1'b0;
        pc_sel = PC_HOLD;

        if (!reset) begin
            case(state)

                FETCH: begin
                    if (inst_two_byte)
                        next_state = FETCH_OPERAND;
                    else
                        next_state = EXECUTE;

                    //WAIT_C
                    if(inst[OPCODE_MSB:OPCODE_LSB] == OP_WAIT_C) begin
                        wait_config_U = 1;
                    end
                end

                FETCH_OPERAND: begin
                    next_state = EXECUTE;

                    //WAIT_C
                    if(ir[OPCODE_MSB:OPCODE_LSB] == OP_WAIT_C) begin
                        wait_config_L = 1;
                    end
                end

                EXECUTE: begin

                    //WAIT_C
                    if(ir[OPCODE_MSB:OPCODE_LSB] == OP_WAIT_C) begin
                        if ({ir[WAIT_C_T_UPPER_MSB:WAIT_C_T_UPPER_LSB], imm} != '0) begin
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
                            wait_start = 1;
                            if(wait_done == 1) begin
                                pc_sel = PC_PLUS_1;
                                next_state = FETCH;
                            end
                            else begin
                                next_state = WAIT_REMAIN;
                            end
                        end
                    end
                end

                WAIT_REMAIN: begin
                    if(wait_done == 1) begin
                        pc_sel = PC_PLUS_1;
                        next_state = FETCH;
                    end
                    else begin
                        next_state = WAIT_REMAIN;
                    end
                end

                default: next_state = FETCH;
            endcase
        end
    end
endmodule
