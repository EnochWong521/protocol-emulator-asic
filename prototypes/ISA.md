# protocol emulator isa

overall 8 bit instructions, 3 bit for instruction select.
- 5 bits remaining for instruction fields
- some instructions span multiple bytes
- exact opcodes TBD

wait_c
- top of instruction memory, configures a wait counter. can span many bytes
- 3 bits for instruction code
- remaining 5 bits TBD
- counter width TBD

wait
- 3 bits for instruction code
- 2 bits for wait duration (full, half, quarter, unused)
- 3 bits unused / TBD
- uses configured wait counter

wait_edge
- 3 bits for instruction code
- 2 bits for pin
- 2 bits for pin state (0, 1, zff, unused)
- 1 bit unused / TBD
- edge vs level detection TBD

loop (2 bytes)
- 3 bits for instruction code
- 5 bits for loop count (0–31)
- 8 bits for loop destintion 2nd byte

shift_in
- 3 bits for instruction code
- pin selection 2 bits
- 1 bit for register (may not be needed?)
- samples a pin into a register

shift_out
- 3 bits for instruction code
- mode selection (shift register data or drive fixed value)
- pin selection 2 bits
- ouput selection 2 bits (Imm0,Imm1,zff, regiser)

branch_pin 2 bytes
- 3 bits for instruction code
- pin selection 2 bits
- pin condition 2 bits (Imm0,Imm1,zff, unused)
- branch destination 8 bits 2nd byte

mov_imm
- 3 bits for instruction code
- current implementation only moves to output reg
- 5 bits for register select avalible?

- next byte holds 8-bit immediate value
- loads constant into register

# still TBD
- exact opcode assignments
- branch address format
- timing overhead between instructions
