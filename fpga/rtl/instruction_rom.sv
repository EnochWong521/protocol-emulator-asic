module instruction_rom #(
    parameter INIT_FILE = "pin_pulse.mem"
) (
    input  wire [7:0] addr,
    output wire [7:0] data
);
    (* rom_style = "distributed" *) logic [7:0] memory [0:255];

    initial $readmemh(INIT_FILE, memory, 0, 255);

    assign data = memory[addr];
endmodule
