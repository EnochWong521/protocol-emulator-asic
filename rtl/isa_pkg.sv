// Protocol Emulator ASIC — complete ISA encoding definitions
//
// One package for RTL and testbenches. Compile this file BEFORE importers:
//   iverilog -g2012 rtl/isa_pkg.sv rtl/... tb/...
//
// Notes:
// - All bit positions below refer to the FIRST instruction byte (IR),
//   unless explicitly labeled OPERAND_BYTE.
// - The optional second byte is always bits [7:0] of OPERAND_BYTE.
// - CMP_EQ/CMP_LT/CMP_GT implement the team's proposed unsigned
//   comparison extension, which must also be reflected in the ISA document.
// - Definitions here do not imply that all instructions have been implemented.

package isa_pkg;

    // ------------------------------------------------------------
    // Common instruction/memory format
    // ------------------------------------------------------------
    localparam int INSTR_WIDTH      = 8;
    localparam int PC_WIDTH         = 8;
    localparam int REG_WIDTH        = 8;
    localparam int T_WIDTH          = 13;
    localparam int GPIO_COUNT       = 4;
    localparam int OPCODE_MSB       = 7;
    localparam int OPCODE_LSB       = 5;
    localparam int OPERAND_BYTE_MSB = 7;
    localparam int OPERAND_BYTE_LSB = 0;
    localparam int ONE_BYTE         = 1;
    localparam int TWO_BYTES        = 2;

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

    typedef enum logic {
        REG_R0 = 1'b0,
        REG_R1 = 1'b1
    } reg_sel_t;

    typedef enum logic [1:0] {
        PIN_P0 = 2'b00,
        PIN_P1 = 2'b01,
        PIN_P2 = 2'b10,
        PIN_P3 = 2'b11
    } pin_sel_t;

    typedef enum logic {
        DIR_RIGHT = 1'b0,
        DIR_LEFT  = 1'b1
    } shift_dir_t;

    // ------------------------------------------------------------
    // 000: WAIT_C (2 bytes)
    // IR[4:0] = T[12:8]; OPERAND_BYTE[7:0] = T[7:0]
    // ------------------------------------------------------------
    localparam int WAIT_C_T_UPPER_MSB = 4;
    localparam int WAIT_C_T_UPPER_LSB = 0;
    localparam int WAIT_C_T_LOWER_MSB = 7;  // OPERAND_BYTE
    localparam int WAIT_C_T_LOWER_LSB = 0;  // OPERAND_BYTE
    localparam logic [12:0] T_RESET_VALUE = 13'd4;
    localparam logic [12:0] T_MIN_VALID   = 13'd1;
    localparam logic [12:0] T_MAX_VALID   = 13'd8191;

    // ------------------------------------------------------------
    // 001: WAIT / SET_DIR (1 byte)
    // IR[4:3] = submode; IR[2:0] = argument
    // WAIT requires argument == 000.
    // SET_DIR requires IR[2:1] == 00 and uses IR[0].
    // ------------------------------------------------------------
    localparam int WAIT_SUBMODE_MSB     = 4;
    localparam int WAIT_SUBMODE_LSB     = 3;
    localparam int WAIT_ARG_MSB         = 2;
    localparam int WAIT_ARG_LSB         = 0;
    localparam logic [2:0] WAIT_ARG_REQUIRED = 3'b000;
    localparam int SET_DIR_RSVD_MSB     = 2;
    localparam int SET_DIR_RSVD_LSB     = 1;
    localparam logic [1:0] SET_DIR_RSVD_REQUIRED = 2'b00;
    localparam int SET_DIR_DIRECTION_BIT = 0;

    typedef enum logic [1:0] {
        WAIT_FULL    = 2'b00,
        WAIT_HALF    = 2'b01,
        WAIT_QUARTER = 2'b10,
        SET_DIR      = 2'b11
    } wait_mode_t;

    // ------------------------------------------------------------
    // 010: PIN_CTRL (1-byte WAIT_PIN / 2-byte BRANCH)
    // IR[4:3] = pin field; IR[2:1] = condition; IR[0] = mode
    // Mode 1: WAIT_PIN, where the condition includes edge modes.
    // Mode 0: BRANCH, where condition 10 means unconditional JMP.
    // For branch condition 11, IR[4] must be 0 and IR[3]
    // selects test of the comparison flag (true vs false).
    // Branch destination = OPERAND_BYTE[7:0] (absolute PC).
    // ------------------------------------------------------------
    localparam int PIN_CTRL_PIN_MSB       = 4;
    localparam int PIN_CTRL_PIN_LSB       = 3;
    localparam int PIN_CTRL_COND_MSB      = 2;
    localparam int PIN_CTRL_COND_LSB      = 1;
    localparam int PIN_CTRL_MODE_BIT      = 0;
    localparam int PIN_CTRL_FLAG_RSVD_BIT = 4;
    localparam logic PIN_CTRL_FLAG_RSVD_REQUIRED = 1'b0;
    localparam int PIN_CTRL_FLAG_SENSE_BIT = 3;
    localparam int PIN_CTRL_TARGET_MSB   = 7;  // OPERAND_BYTE
    localparam int PIN_CTRL_TARGET_LSB   = 0;  // OPERAND_BYTE

    typedef enum logic {
        PIN_BRANCH_MODE = 1'b0,
        PIN_WAIT_MODE   = 1'b1
    } pin_ctrl_mode_t;

    typedef enum logic [1:0] {
        PIN_WAIT_LOW     = 2'b00,
        PIN_WAIT_HIGH    = 2'b01,
        PIN_WAIT_RISING  = 2'b10,
        PIN_WAIT_FALLING = 2'b11
    } pin_wait_cond_t;

    typedef enum logic [1:0] {
        PIN_BR_LOW   = 2'b00,
        PIN_BR_HIGH  = 2'b01,
        PIN_BR_JMP   = 2'b10,
        PIN_BR_FLAG  = 2'b11
    } pin_branch_cond_t;

    typedef enum logic {
        BR_FLAG_TRUE  = 1'b0,  // IR[3]=0: BR_TRUE (formerly BR_EQ)
        BR_FLAG_FALSE = 1'b1   // IR[3]=1: BR_FALSE (formerly BR_NE)
    } branch_flag_sense_t;

    // ------------------------------------------------------------
    // 011: LOOP (2 bytes)
    // IR[4:0] = count (0 encodes 32); OPERAND_BYTE = target PC
    // ------------------------------------------------------------
    localparam int LOOP_COUNT_MSB      = 4;
    localparam int LOOP_COUNT_LSB      = 0;
    localparam int LOOP_TARGET_MSB     = 7; // OPERAND_BYTE
    localparam int LOOP_TARGET_LSB     = 0; // OPERAND_BYTE
    localparam logic [4:0] LOOP_COUNT_32_ENCODING = 5'd0;
    localparam int LOOP_COUNT_32_ITERATIONS = 32;

    // ------------------------------------------------------------
    // 100: SHIFT_IN (1 byte)
    // IR[4] = register; IR[3:2] = pin; IR[1:0] must be 00
    // ------------------------------------------------------------
    localparam int SHIFT_IN_REG_BIT     = 4;
    localparam int SHIFT_IN_PIN_MSB     = 3;
    localparam int SHIFT_IN_PIN_LSB     = 2;
    localparam int SHIFT_IN_RSVD_MSB    = 1;
    localparam int SHIFT_IN_RSVD_LSB    = 0;
    localparam logic [1:0] SHIFT_IN_RSVD_REQUIRED = 2'b00;

    // ------------------------------------------------------------
    // 101: SHIFT_OUT (1 byte)
    // IR[4] = register; IR[3:2] = pin; IR[1:0] = output mode
    // ------------------------------------------------------------
    localparam int SHIFT_OUT_REG_BIT    = 4;
    localparam int SHIFT_OUT_PIN_MSB    = 3;
    localparam int SHIFT_OUT_PIN_LSB    = 2;
    localparam int SHIFT_OUT_MODE_MSB   = 1;
    localparam int SHIFT_OUT_MODE_LSB   = 0;

    typedef enum logic [1:0] {
        SHIFT_OUT_LOW     = 2'b00,
        SHIFT_OUT_HIGH    = 2'b01,
        SHIFT_OUT_RELEASE = 2'b10,
        SHIFT_OUT_SHIFT   = 2'b11
    } shift_out_mode_t;

    // ------------------------------------------------------------
    // 110: MOVE / CMP (1 or 2 bytes)
    // IR[4] = selected register; IR[3:2] = submode; IR[1:0]
    // must be 00 for MOV, or selects CMP operation for CMP.
    // For immediate submodes, OPERAND_BYTE[7:0] is the imm8.
    // CMP_LT / CMP_GT are UNSIGNED comparisons.
    // ------------------------------------------------------------
    localparam int MOVE_REG_BIT         = 4;
    localparam int MOVE_SUBMODE_MSB     = 3;
    localparam int MOVE_SUBMODE_LSB     = 2;
    localparam int MOVE_LOW_MSB         = 1;
    localparam int MOVE_LOW_LSB         = 0;
    localparam int CMP_OP_MSB           = 1;
    localparam int CMP_OP_LSB           = 0;
    localparam int MOVE_IMMEDIATE_MSB   = 7; // OPERAND_BYTE
    localparam int MOVE_IMMEDIATE_LSB   = 0; // OPERAND_BYTE
    localparam logic [1:0] MOV_LOW_REQUIRED = 2'b00;

    typedef enum logic [1:0] {
        MOV_IMM = 2'b00,
        CMP_IMM = 2'b01,
        MOV_REG = 2'b10,
        CMP_REG = 2'b11
    } move_submode_t;

    typedef enum logic [1:0] {
        CMP_EQ       = 2'b00,
        CMP_LT       = 2'b01,
        CMP_GT       = 2'b10,
        CMP_RESERVED = 2'b11
    } cmp_op_t;

    // ------------------------------------------------------------
    // 111: DATA_IO (1 byte)
    // IR[4] = register; IR[3] = PULL/PUSH; IR[2:0] must be 000
    // ------------------------------------------------------------
    localparam int DATA_IO_REG_BIT      = 4;
    localparam int DATA_IO_MODE_BIT     = 3;
    localparam int DATA_IO_RSVD_MSB     = 2;
    localparam int DATA_IO_RSVD_LSB     = 0;
    localparam logic [2:0] DATA_IO_RSVD_REQUIRED = 3'b000;

    typedef enum logic {
        DATA_PULL = 1'b0,
        DATA_PUSH = 1'b1
    } data_io_mode_t;

endpackage
