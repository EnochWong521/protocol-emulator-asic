// Shared instruction-set definitions for the protocol emulator.
// Compile this package before RTL modules and testbenches that import it.
package isa_pkg;

    // Common instruction encoding: [7:5] opcode, [4:0] instruction-specific.
    localparam int OPCODE_MSB = 7;
    localparam int OPCODE_LSB = 5;

    // Fields shared by SHIFT_IN, SHIFT_OUT, and MOVE/CMP.
    localparam int REG_SEL_BIT = 4;
    localparam int PIN_SEL_MSB = 3;
    localparam int PIN_SEL_LSB = 2;
    localparam int LOW_MODE_MSB = 1;
    localparam int LOW_MODE_LSB = 0;

    // Submode bit positions differ between WAIT and MOVE/CMP.
    localparam int WAIT_SUBMODE_MSB = 4;
    localparam int WAIT_SUBMODE_LSB = 3;
    localparam int MOVE_SUBMODE_MSB = 3;
    localparam int MOVE_SUBMODE_LSB = 2;

    typedef enum logic [2:0] {
        OP_WAIT_C    = 3'b000,
        OP_WAIT      = 3'b001,
        OP_PIN_CTRL  = 3'b010,
        OP_LOOP      = 3'b011,
        OP_SHIFT_IN  = 3'b100,
        OP_SHIFT_OUT = 3'b101,
        OP_MOVE      = 3'b110,
        OP_DATA_IO   = 3'b111
    } opcode_t;

    typedef enum logic [1:0] {
        WAIT_FULL    = 2'b00,
        WAIT_HALF    = 2'b01,
        WAIT_QUARTER = 2'b10,
        SET_DIR      = 2'b11
    } wait_mode_t;

    typedef enum logic [1:0] {
        MOV_IMM = 2'b00,
        CMP_IMM = 2'b01,
        MOV_REG = 2'b10,
        CMP_REG = 2'b11
    } move_submode_t;

    // Proposed CMP extension: unsigned 8-bit comparisons.
    typedef enum logic [1:0] {
        CMP_EQ       = 2'b00,
        CMP_LT       = 2'b01,
        CMP_GT       = 2'b10,
        CMP_RESERVED = 2'b11
    } cmp_op_t;

    typedef enum logic [1:0] {
        SHIFT_OUT_LOW     = 2'b00,
        SHIFT_OUT_HIGH    = 2'b01,
        SHIFT_OUT_RELEASE = 2'b10,
        SHIFT_OUT_SHIFT   = 2'b11
    } shift_out_mode_t;

endpackage
