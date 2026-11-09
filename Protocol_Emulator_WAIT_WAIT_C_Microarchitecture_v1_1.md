# Protocol Emulator ASIC — WAIT_C / WAIT Microarchitecture

**Status:** Current standalone controller/fetch/PC/timer RTL and tests. `protocol_core` and complete instruction-level datapath integration remain pending.
**Encoding reference:** `protocol_emulator_ISA_v1_proposed.md` and `rtl/isa_pkg.sv`.
**Architecture:** Sequential, non-pipelined; combinational-read instruction memory.

This revision replaces the historical combined `instruction_control` interface examples. Current modules are `control_unit`, `inst_fetch`, `pc` and `wait_timer`. There are no `retire`, `illegal_inst`, `wait_done`, `wait_config_U`, or `wait_config_L` ports.

## 1. State ownership and connections

| State | Owner | Reset |
|---|---|---|
| PC, 8 bits | `pc` | 0 |
| IR and IMM, 8 bits each | `inst_fetch` | 0 |
| FSM, 2 bits | `control_unit` | FETCH |
| Persistent `direction` | `control_unit` | RIGHT = 0 |
| T, 13 bits | `wait_timer` | 4 |
| Remaining execution count, 13 bits | `wait_timer` | 0 |

All resets are active-high and synchronous. The PC, fetch and controller ports are named `reset`; the timer and data/comparison datapaths use `rst`. Integration supplies the same reset to them.

```text
pc.pc -> inst_fetch.pc_value
memory[inst_addr] -> inst_fetch.inst and control_unit.inst
inst_fetch.ir -> control_unit.ir
control_unit.ir_load/imm_load -> inst_fetch capture enables
control_unit.pc_sel -> pc.pc_sel
control_unit.wait_start/wait_tick/wait_c_write/wait_mode -> wait_timer
wait_timer.wait_is_single_cycle/wait_is_last_cycle -> control_unit
```

Integration forms the data and legality condition:

```systemverilog
assign t_write_data = {ir[WAIT_C_T_UPPER_MSB:WAIT_C_T_UPPER_LSB], imm};
assign wait_c_nonzero = |t_write_data;
```

`t_write_data` feeds the timer; only `wait_c_nonzero` enters the controller. This checks the full candidate T, not the previous T or only IMM. For example, byte pair `01 00` programs 256 and is legal.

The timer ports are:

```systemverilog
module wait_timer (
    input  logic        clk,
    input  logic        rst,
    input  logic        wait_c_write,
    input  logic [12:0] t_write_data,
    input  logic        wait_start,
    input  logic [1:0]  wait_mode,
    input  logic        wait_tick,
    output logic        wait_is_single_cycle,
    output logic        wait_is_last_cycle
);
```

`t_reg`, `wait_duration` and `wait_remaining` are internal signals used by the testbench for observation. They are not extra output ports. WAIT mode encodings and T reset value come from `isa_pkg`.

## 2. Encoding and instruction lengths

| Instruction | First byte | Second byte | Length |
|---|---|---|---|
| WAIT_C | `[7:5]=000`, `[4:0]=T[12:8]` | T[7:0] | 2 |
| WAIT FULL | `20` hex | None | 1 |
| WAIT HALF | `28` hex | None | 1 |
| WAIT QUARTER | `30` hex | None | 1 |
| SET_DIR RIGHT | `38` hex | None | 1 |
| SET_DIR LEFT | `39` hex | None | 1 |

WAIT arguments `[2:0]` must be zero. SET_DIR requires `[2:1]=00` and uses bit zero for direction. SET_DIR changes the persistent direction flag and never starts the timer.

WAIT_C configures a generic system-clock period, not a dedicated UART clock. Valid T is 1 through 8191. Zero is reserved: the controller stalls without writing T or advancing PC. The timer trusts legal controller strobes; it does not independently validate T.

Length decoding is separate from execution legality. Two-byte encodings are WAIT_C, LOOP, PIN_CTRL with mode bit zero, and MOVE submodes MOV_IMM/CMP_IMM. Reserved immediate encodings still fetch an operand before execution stalls. PIN_CTRL, LOOP and DATA_IO execution remain future work.

## 3. Four-state controller and PC selection

| State | Address | Capture/operation | PC |
|---|---|---|---|
| FETCH = 00 | PC | `ir_load=1`; dispatch by live `inst` length | Hold |
| FETCH_OPERAND = 01 | PC+1 | `imm_load=1`; next EXECUTE | Hold |
| EXECUTE = 10 | PC, unused for execution | Execute saved IR/IMM | Advance on completion only |
| WAIT_REMAIN = 11 | PC, unused | Tick remaining wait count | Hold until final tick |

`ir_load` and `imm_load` are suppressed while reset is asserted. `inst_fetch` selects PC+1 when `imm_load` is high and otherwise PC. It owns IR/IMM and address selection; the controller owns the capture controls. No architectural PC change occurs during fetch.

| `pc_sel` | PC action at rising edge |
|---|---|
| PC_HOLD = 00 | Hold |
| PC_PLUS_1 = 01 | PC + 1 |
| PC_PLUS_2 = 10 | PC + 2 |
| 11 | Reserved; currently hold |

Arithmetic wraps modulo 256. Firmware/assembler must avoid instructions crossing the image end or targeting operand bytes. Future branch support requires a target input/selection; it is not implemented. Completion/retirement means the final execution edge, not an additional state or register.

## 4. Timer edge contract

Duration D is T for FULL, max(1,T>>1) for HALF and max(1,T>>2) for QUARTER. SET_DIR selects no wait duration and must never assert `wait_start`.

- Legal WAIT_C: assert `wait_c_write` in EXECUTE. At the ending edge, atomically load all 13 bits of T, select PC_PLUS_2 and return to FETCH.
- First WAIT execution cycle: assert `wait_start`. At its ending edge, load `wait_remaining=D-1` because this cycle already counts toward D.
- D=1: `wait_is_single_cycle=1`; that same edge selects PC_PLUS_1 and returns to FETCH. WAIT_REMAIN is skipped.
- D>1: enter WAIT_REMAIN. Assert `wait_tick` in each remaining cycle and decrement once per edge.
- When the pre-edge counter is one, `wait_is_last_cycle=1`. The final tick takes it to zero while PC advances by one and state returns to FETCH.

Timer status flags are combinational. Registering them would add a cycle. T holds throughout WAIT and all non-WAIT_C instructions. The controller never restarts a WAIT in WAIT_REMAIN.

`wait_c_write`, `wait_start` and `wait_tick` are mutually exclusive and are low during reset and fetch. Valid control never ticks zero or starts SET_DIR. The timer's subtractors are not saturating; testbenches check those interface preconditions instead of adding hardware guards.

| Instruction | Fetch cycles | Execution cycles | Total |
|---|---:|---:|---:|
| WAIT_C | 2 | 1 | 3 |
| WAIT FULL | 1 | T | 1+T |
| WAIT HALF | 1 | max(1,T>>1) | 1+D |
| WAIT QUARTER | 1 | max(1,T>>2) | 1+D |
| Ordinary one-byte instruction | 1 | 1 | 2 |
| Ordinary two-byte instruction | 2 | 1 | 3 |

Unsupported/reserved instructions hold in EXECUTE with PC held and write strobes low. Current RTL has no separate fault indicator; tests deliberately exercise these stalls. Do not interpret a stalled unsupported instruction as a NOP.

## 5. Reference timing

For T=4, WAIT FULL has one fetch, one EXECUTE and three WAIT_REMAIN cycles: five clocks total. For T=1, all three WAIT modes take two clocks including fetch.

Reference program bytes: `01 B2 20 28 30`.

| Clock edge | Action | PC after edge |
|---|---|---|
| 1–2 | Fetch WAIT_C 434 | 00 |
| 3 | Write T=434 | 02 |
| 4 | Fetch WAIT FULL | 02 |
| 5 | Start FULL; load 433 | 02 |
| 6–438 | Remaining FULL cycles; complete at 438 | 03 at completion |
| 439 | Fetch HALF | 03 |
| 440 | Start HALF; load 216 | 03 |
| 441–656 | Remaining HALF cycles; complete at 656 | 04 at completion |
| 657 | Fetch QUARTER | 04 |
| 658 | Start QUARTER; load 107 | 04 |
| 659–765 | Remaining QUARTER cycles; complete at 765 | 05 at completion |

Total is 3+(1+434)+(1+217)+(1+108)=765 clocks. A following instruction can fetch only after completion.

For repeated `SHIFT_OUT; WAIT D; SHIFT_OUT`, the output-edge interval is D+3 clocks. An intervening two-byte LOOP would add three more clocks once LOOP is implemented. Protocol periods must include instruction overhead, not only T.

## 6. Verification and integration status

- `tb_wait_timer`: 25 standalone cases, including all three modes at T=1,2,3,4,7,434,8191, configuration retention, SET_DIR duration selection and reset during countdown.
- `tb_control_unit`: atomic full-width T updates, rejected zero configuration, original six-instruction/25-cycle program, and 24 WAIT/8 WAIT_C timing cases including T=256 and the 765-cycle reference.
- `tb_control_unit_fetch`: all 256 first-byte lengths, capture/retention, legal and reserved SHIFT/MOVE/CMP encodings, timer strobes and reset command suppression.
- `tb_pc`: all byte addresses, hold, modulo wraparound, synchronous reset and reserved selection.

See `README.md` for commands. Tests drive on falling edges and sample register results after rising-edge nonblocking updates. RTL contains no simulation delays.

Remaining work: connect `protocol_core` to the shift/MOVE and comparison datapaths, test instruction-driven GPIO/flag timing and direction changes, then add the future instruction families separately. Program-memory loading, physical pads and host transport remain system-level work.
