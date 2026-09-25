`timescale 1ns / 1ps

module uart_tx #parameter (
  BAUD_RATE = 115200,
  DATA_WIDTH = 8
  )
(
  input logic clk,
  input logic rst_n,
  input logic start,
  input logic [DATA_WIDTH - 1:0] data_in,
  output logic tx,
  output logic busy,
  output logic done
  );

  // FSM states
  typedef enum logic [1:0] {
    IDLE, 
    START,
    DATA, 
    STOP
    } state_t;

  // state registers
  logic [1:0] next_state;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end
  
  // baud rate logic 
  

  // next state logic
  always_comb begin
    unique case (state)
      IDLE : next_state = start ? START : IDLE;
      START : next_state = DATA;
      DATA : next_state = data_last ? STOP : DATA;
      STOP : next_state = IDLE;
    endcase
  end
endmodule;
