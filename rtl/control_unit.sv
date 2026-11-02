module control_unit (
    input   logic [7:0]   inst,
    input   logic         clk,
    input   logic         reset,
    input   logic         wait_done,

    output  logic         wait_start,
    output  logic         wait_config_U,
    output  logic         wait_config_L,
    output  logic         PC_update,
    output  logic         direction
);

    typedef enum logic [2:0] {
        IDLE,
        FETCH,
        FETCH_BYTE_2,
        EXECUTE,
        WAITING
    } state_t;

    state_t state, next_state;
    logic [2:0] opcode_prev;
    logic [4:0] argument_prev;

    always_ff @(posedge clk) begin
        if (reset == 1) begin
            state <= IDLE;
            opcode_prev <= 3'b000;
            argument_prev <= 5'b00000;
            direction <= 1'b0;
        end
        else begin
            state <= next_state;
            // Save the instruction fields

            if(state == FETCH) begin
                opcode_prev <= inst[7:5];
                argument_prev <= inst[4:0];
            end

            // reguister setdir
            if(state == EXECUTE &&
               opcode_prev == 3'b001 &&
               argument_prev[4:1] == 4'b1100) begin
                direction <= argument_prev[0];
            end
        end
    end

    always_comb begin
        next_state = state;

        wait_start = 0;
        wait_config_U = 0;
        wait_config_L = 0;
        PC_update = 0;

        case(state)

            IDLE: begin
                next_state = FETCH;
            end

            FETCH: begin

                //WAIT_C
                if(inst[7:5] == 3'b000) begin
                    wait_config_U = 1;
                    PC_update = 1;
                    next_state = FETCH_BYTE_2;
                end

                //WAIT / SET_DIR
                else if(inst[7:5] == 3'b001) begin
                    PC_update = 1;
                    next_state = EXECUTE;
                end
            end

            FETCH_BYTE_2: begin

                //WAIT_C
                if(opcode_prev == 3'b000) begin
                    wait_config_L = 1;
                    PC_update = 1;
                    next_state = EXECUTE;
                end
            end

            EXECUTE: begin

                //WAIT_C
                if(opcode_prev == 3'b000) begin
                    next_state = FETCH;
                end

                //WAIT / SET_DIR
                else if(opcode_prev == 3'b001) begin

                    //SET_DIR
                    if(argument_prev[4:1] == 4'b1100) begin
                        next_state = FETCH;
                    end

                    //WAIT
                    else if(argument_prev[4:3] != 2'b11 &&
                            argument_prev[2:0] == 3'b000) begin
                        wait_start = 1;
                        if(wait_done == 1) begin
                            next_state = FETCH;
                        end
                        else begin
                            next_state = WAITING;
                        end
                    end
                end
            end

            WAITING: begin
                if(wait_done == 1) begin
                    next_state = FETCH;
                end
                else begin
                    next_state = WAITING;
                end
            end

            default: next_state = IDLE;
        endcase
    end
endmodule