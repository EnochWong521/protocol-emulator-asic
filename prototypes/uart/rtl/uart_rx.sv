// 1 start
// 8 data
// 1 parity
// 115200

module uart_rx #(
    parameter CLKS_PER_BIT = 868 //100MHz / 115200
)(
    input logic clk,
    input logic rst_n,
    input logic rx,              
    output logic [7:0] rx_data,
    output logic rx_valid,       // Pulse when data is ready
    output logic parity_error
);

    // Idle state
        //scanning for rx low = start 

    // Start
        //move half a bit
    // Receive state
        //sample in the middle of a bit
        //shift into an array
        //after 8 cycles check parity
    
    //parity
        //see if the parity bit is as expected

    //stop 
        //set rx data valid
        //wiat one cycle go to idle

    // Internal registers
    logic [15:0] clk_count;
    logic [2:0]  bit_index;
  
    // FSM states
    typedef enum logic [2:0] {
        IDLE, 
        START,
        DATA,
        PARITY, 
        STOP
    } state_t;

    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            clk_count    <= 0;
            bit_index    <= 0;
            rx_valid     <= 1'b0;
            parity_error <= 1'b0;
            rx_data      <= 8'd0;
        end else begin
            rx_valid <= 1'b0;

            case (state)
                IDLE: begin
                    if (rx == 1'b0) begin
                        state <= START;
                    end else begin 
                        state <= IDLE;
                    end
                end

                START: begin
                    // Wait till we're in the middle of the first data bit then go to data
                    if (clk_count == (CLKS_PER_BIT / 2)) begin
                        clk_count <= 0;
                        state     <= DATA;
                    end else begin
                        clk_count <= clk_count + 1; 
                        state     <= START;
                    end
                end

                DATA: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 0;
                        rx_data[bit_index] <= rx;
                        if (bit_index == 7) begin
                            bit_index <= 0;
                            state     <= PARITY;
                        end else begin
                            bit_index <= bit_index + 1;
                            state     <= DATA;
                        end
                    end else begin
                        clk_count <= clk_count + 1;
                        state     <= DATA;
                    end
                end

                PARITY: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 0;
                        // ^ checks parity
                        if (^rx_data != rx) begin
                            parity_error <= 1'b1;
                        end else begin
                            parity_error <= 1'b0;
                        end
                        
                        state <= STOP; 
                    end else begin
                        clk_count <= clk_count + 1;
                        state     <= PARITY;
                    end
                end

                STOP: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 0;
                        rx_valid  <= 1'b1; 
                        state     <= IDLE;
                    end else begin
                        clk_count <= clk_count + 1;
                        state     <= STOP;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule