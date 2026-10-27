module control_unit (
    input   logic [7:0]   inst,
    input   logic         clk,
    input   logic         reset,
    input   logic         wait_done,

    output  logic         wait_start,
    output  logic         wait_config_U,
    output  logic         wait_config_L,
    output  logic         PC_update
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

    always_ff @(posedge clk) begin
        if (reset == 1) begin
            state <= IDLE;
            opcode_prev <= 3'b000;
        end
        else begin
            state <= next_state;

            if(state == FETCH)
                opcode_prev <= inst[7:5];
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

    //WAIT
                else if(inst[7:5] == 3'b001) begin
                    PC_update = 1;
                    next_state = EXECUTE;
                end

            end

            FETCH_BYTE_2: begin
    //WAIT_C BYTE2
                if(opcode_prev == 3'b000) begin
                    wait_config_L = 1;
                    PC_update = 1;
                    next_state = FETCH;
                end
            end

            EXECUTE: begin
                wait_start = 1;
                if(wait_done == 1) begin
                    next_state = FETCH;
                end
                else begin
                    next_state = WAITING;
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