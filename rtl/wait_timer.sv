module wait_timer (
    input  logic        clk,
    input  logic        rst,
    input  logic        wait_c_write,
    input  logic [12:0] t_write_data,
    input  logic        wait_start,
    input  logic [1:0]  wait_mode,
    input  logic        wait_tick,
    input  logic        wait_rebase, // Completed WAIT_PIN anchors external-event timing.
    output logic        wait_is_single_cycle,
    output logic        wait_is_last_cycle,
    output logic        timing_overrun
);
    import isa_pkg::*;
    logic [12:0] t_reg, wait_duration, wait_remaining;
    logic [12:0] elapsed_cycles;
    logic epoch_valid;
    logic [13:0] elapsed_on_edge;
    logic wait_complete;

    always_comb begin
        case (wait_mode)
            WAIT_FULL:    wait_duration = t_reg;
            WAIT_HALF:    wait_duration = t_reg >> 1;
            WAIT_QUARTER: wait_duration = t_reg >> 2;
            default:      wait_duration = 13'd0;
        endcase
        if (wait_mode != SET_DIR && wait_duration == 0)
            wait_duration = 13'd1;
    end

    // Include the upcoming execution edge. Before the first WAIT completion,
    // no epoch exists: that first WAIT spends D execution clocks establishing it.
    assign elapsed_on_edge = {1'b0, elapsed_cycles} + 14'd1;
    assign wait_is_single_cycle = (wait_mode != SET_DIR) &&
                                  (elapsed_on_edge >= {1'b0, wait_duration});
    assign wait_is_last_cycle = (wait_remaining == 13'd1);
    assign wait_complete = (wait_start && wait_is_single_cycle) ||
                           (wait_tick && wait_is_last_cycle);

    always_ff @(posedge clk) begin
        if (rst) begin
            t_reg <= T_RESET_VALUE;
            wait_remaining <= 13'd0;
            elapsed_cycles <= 13'd0;
            epoch_valid <= 1'b0;
            timing_overrun <= 1'b0;
        end else begin
            if (wait_c_write) t_reg <= t_write_data;

            // Every clock after a WAIT completion counts, including fetch, LOOP,
            // configuration writes and GPIO waits. Saturation prevents wrapping.
            if (wait_complete || wait_rebase) begin
                elapsed_cycles <= 13'd0;
                epoch_valid <= 1'b1;
            end else if (epoch_valid && elapsed_cycles != T_MAX_VALID) begin
                elapsed_cycles <= elapsed_cycles + 13'd1;
            end

            if (wait_start) begin
                if (wait_is_single_cycle)
                    wait_remaining <= 13'd0;
                else
                    wait_remaining <= wait_duration - elapsed_on_edge[12:0];
                if (epoch_valid && elapsed_on_edge > {1'b0, wait_duration})
                    timing_overrun <= 1'b1;
            end else if (wait_tick && wait_remaining != 0) begin
                wait_remaining <= wait_remaining - 13'd1;
            end
        end
    end
endmodule
