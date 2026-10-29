module wait_timer (
    input  logic        clk,
    input  logic        rst,
    input  logic        wait_c_write,
    input  logic [12:0] t_write_data,
    input  logic        wait_start,
    input  logic [1:0]  wait_mode,
    input  logic        wait_tick,

    output logic        wait_is_single_cycle,
    output logic        wait_is_last_cycle,
);


  // timer configuration register
  logic [12:0] t_reg;

  always_ff @(posedge clk) begin
    if (rst) begin
      t_reg <= 13'd4;
    end else if (wait_c_write) begin
      t_reg <= t_write_data;
    end
  end

  // duration selection logic 
  typedef enum logic[1:0] {
    WAIT_FULL,
    WAIT_HALF,
    WAIT_QUARTER,
    SET_DIR
  } wait_mode_t;
  
  logic [12:0] wait_duration;

  always_comb begin
    unique case (wait_mode)
      WAIT_FULL : wait_duration = t_reg;
      WAIT_HALF : wait_duration = t_reg >> 1;
      WAIT_QUARTER : wait_duration = t_reg >> 2;
      SET_DIR: wait_duration = 13'd0;
    end case

    if (wait_mode != SET_DIR && wait_duration == 13'd0) begin
      wait_duration = 13'd1;
    end
  end

  // countdown timer
  logic [12:0] wait_remaining;

  always_ff @(posedge clk) begin
    if (rst) begin
      wait_remaining <= 13'd0;
    // load counter with wait duration
    // minus 1 because execute stage consumes one cycle
    end else if (wait_duration) begin
      wait_remaining <= wait_duration - 13'd1;
    // countdown
    end else begin
      wait_remaining <= wait_remaining - 13'd1;
    end
  end
  
  // status flags
  // edge case when wait duration is 1
  assign wait_is_single_cycle = (wait_duration == 13'd1) && (wait_mode != SET_DIR);

  // countdown completion
  assign wait_is_last_cycle = (wait_remaining == 13'b1);
endmodule;
