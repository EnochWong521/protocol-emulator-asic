`timescale 1ns / 1ps

module uart_tx(
  input logic clk,
  input logic rst_n,
  input logic start,
  input logic [7:0] data_in,
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

  

endmodule;
