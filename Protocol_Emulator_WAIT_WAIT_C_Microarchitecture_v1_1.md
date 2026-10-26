# Protocol Emulator ASIC — `WAIT_C` / `WAIT` Microarchitecture

**Status:** Proposed v1.1 implementation + two-person integration freeze — **not yet RTL-verified**  
**Scope:** First RTL milestone: instruction fetch, program counter, `WAIT_C`, and `WAIT` only; includes a frozen two-person collaboration contract  
**Architecture:** Sequential, **non-pipelined**, multi-cycle processor  
**ISA authority:** `protocol_emulator_ISA_v1_proposed(2).md` (UART-capable v1.0 proposal)

> **Compatibility note — read first:** The ISA specifies that `WAIT D` spends **exactly D cycles in execution**, including its first `EXECUTE` cycle, and that the PC updates **when the instruction retires**. An earlier architecture discussion instead counted D additional `WAIT` cycles after `EXECUTE` and incremented the PC during fetch. **This README deliberately follows the uploaded ISA.** Thus a one-byte `WAIT D` takes **1 + D total cycles**, not `2 + D`; the PC does **not** advance during either fetch state.

---

## 1. Objectives and non-goals

### Objectives

1. Implement bit-accurate decoding of `WAIT_C` and `WAIT` without altering the ISA encoding.
2. Support a 256 × 8-bit preloaded instruction image with an 8-bit byte-addressed PC.
3. Guarantee atomic updates of the persistent 13-bit timing register `T`.
4. Guarantee **exactly D execution cycles** for `WAIT FULL`, `WAIT HALF`, and `WAIT QUARTER`.
5. Keep all hardware synchronous to `clk` (no derived or gated clocks).
6. Keep instruction-fetch control reusable for later `PIN_CTRL`, `LOOP`, `MOVE`, and other ISA groups.
7. Define every clock edge, PC update, register enable, and testable invariant before coding.

### Out of scope for milestone 1

- `SET_DIR` effects, GPIO, shift registers, branches, loop counter, host mailboxes, and input synchronizers.
- Actual SPI/UART/I²C generation and protocol performance claims.
- A production instruction-loader interface or a final program-memory macro.
- Pipelining, branch prediction, and instruction flushing.

**Important:** Unsupported opcodes in this milestone should produce a simulation failure or explicit *unimplemented* indication. Do not silently execute them as NOPs or invent new ISA behavior.

---

## 2. Relevant frozen ISA

### 2.1 Instruction format

- Each opcode byte uses `[7:5]` for the primary opcode.
- Instructions are one or two bytes, stored in a byte-addressed 256 × 8-bit instruction memory.
- `PC` is 8 bits. Reset value: `0x00`.

**`WAIT_C` — opcode `000`, two bytes**

```text
Byte 0 at PC:     [7:5] = 000   [4:0] = T[12:8]
Byte 1 at PC+1:   [7:0] = T[7:0]
T_new = {IR[4:0], IMM[7:0]}
Valid programmed T: 1 ... 8191 (zero is illegal per ISA)
```

**`WAIT` / `SET_DIR` — opcode `001`, one byte**

```text
[7:5] opcode = 001
[4:3] sub_mode
[2:0] argument

sub_mode  argument    Operation
00        000         WAIT FULL       D = T
01        000         WAIT HALF       D = max(1, T >> 1)
10        000         WAIT QUARTER    D = max(1, T >> 2)
11        00d         SET_DIR         (future milestone)
```

Any other argument for a WAIT submode is reserved and must not be treated as a legal WAIT instruction.

`T` is a generic **system-clock period**, not a UART-specific baud-rate register.

### 2.2 Execution-time contract

| Instruction | Fetch cycles | Execution cycles | Total cycles |
|---|---:|---:|---:|
| `WAIT_C T` | 2 | 1 | **3** |
| `WAIT FULL` | 1 | `T` | **`1 + T`** |
| `WAIT HALF` | 1 | `max(1, T >> 1)` | **`1 + D`** |
| `WAIT QUARTER` | 1 | `max(1, T >> 2)` | **`1 + D`** |
| Other nonblocking, one-byte instructions (future) | 1 | 1 | **2** |
| Other nonblocking, two-byte instructions (future) | 2 | 1 | **3** |

**Retirement:** An instruction retires at the rising edge completing its final execution cycle. At that edge, the PC advances by its instruction length, unless a future branch redirects it.

---

## 3. Minimal datapath

```text
                           +-----------------------------+
                           | Instruction memory 256 x 8  |
                           | (combinational read in v1)  |
                           +--------------+--------------+
                                          ^ address
                                          |
                              +-----------+-----------+
                              | FETCH address select  |
                              | PC or PC + 1          |
                              +-----------+-----------+
                                          ^
                                          |
                                    PC [7:0]
                                          |
                +-------------------------+-------------------+
                |                                             |
                v                                             v
       +-------------------+                         +------------------+
       | Opcode reg IR[7:0]|                         | Operand IMM[7:0] |
       +--------+----------+                         +---------+--------+
                |                                              |
                +------------+---------------------------------+
                             | WAIT_C: {IR[4:0], IMM}
                             v
                   +-----------------------+
                   | T register [12:0]     |
                   | write only on WAIT_C  |
                   +-----------+-----------+
                               |
                      +--------+--------+
                      |        |        |
                      v        v        v
                     T       T >> 1   T >> 2    (constant shifts = wiring)
                      +--------+--------+
                               |
                       3-way selection
                        by IR[4:3]
                               |
                       clamp zero to 1
                               |
                          D [12:0]
                               |
                        D - 1 on entry
                               |
                               v
                   +-----------------------+
                   | wait_remaining[12:0]  |
                   | decrement each        |
                   | WAIT_REMAIN cycle     |
                   +-----------+-----------+
                               |
                      remaining == 1?
                               |
                               v
                    Control FSM / retire
                               |
                       PC <- PC + length
```

This is a logical drawing, not a required module-boundary partition. `PC + 1` can serve operand fetch; a future PC source mux adds branch/loop targets.

**No variable barrel shifter is necessary.** `T >> 1` and `T >> 2` are fixed slices padded with zeros. The synthesis cost comes mainly from the selection logic, zero clamp, decrementing, and registers.

---

## 4. Required sequential state

| Register | Width | Synchronous reset | Write condition | Purpose |
|---|---:|---|---|---|
| `pc` | 8 | `0x00` | Instruction retirement | Address of the *current* opcode until it retires |
| `ir` | 8 | `0x00` (implementation choice) | `FETCH_OPCODE` | Holds full first instruction byte |
| `imm` | 8 | `0x00` (implementation choice) | `FETCH_OPERAND` | Holds second byte for two-byte instructions |
| `t_reg` | 13 | **13'd4** (ISA-required) | `WAIT_C` retirement only | Persistent programmable time base |
| `wait_remaining` | 13 | `0` | WAIT execution entry / remaining cycles | Cycles remaining **after** the first execution cycle |
| `state` | 2 | `FETCH_OPCODE` | Every state transition | Four-state control FSM |

**Total:** 52 flip-flops for these registers, excluding instruction memory and all future ISA state. Reset values for `ir` and `imm` are implementation choices; neither is architecturally visible until loaded. Their reset might be omitted later if proven safe by control and verification.

**Why two 13-bit timing registers?** A WAIT must not overwrite the persistent T configuration. Subsequent WAIT instructions need the same programmed base period.

**No separate `NEXT`, `wait_done`, or `T_valid` register is needed.** The fetch FSM handles two-byte instructions. A one-cycle `wait_c_write` updates T; otherwise it holds automatically. `T` is valid after reset because the ISA defines `T=4`.

---

## 5. Control FSM

Use **one FSM** for fetch and execution. These four physical states implement the ISA's three conceptual phases (`FETCH_OPCODE`, optional `FETCH_OPERAND`, `EXECUTE`), where an extended `WAIT_REMAIN` state is still part of the WAIT instruction's *execution phase*.

```text
              +----------------------+
       +----->|    FETCH_OPCODE      |
       |      | IR <= mem[PC]        |
       |      +----------------------+
       |           |            |
       |      1-byte            2-byte
       |           |            v
       |           |    +----------------------+
       |           |    |   FETCH_OPERAND      |
       |           |    | IMM <= mem[PC + 1]   |
       |           |    +----------------------+
       |           |            |
       |           v            v
       |      +----------------------+
       |      |       EXECUTE        |
       |      | ordinary: retire     |
       |      | WAIT D=1: retire     |
       |      | WAIT D>1: load D-1   |
       |      +----------------------+
       |        |                |
       |     retired          WAIT D>1
       |        |                v
       |        |      +----------------------+
       |        |      |     WAIT_REMAIN      |
       |        |      | count down each      |
       |        |      | clock; final retire  |
       |        |      +----------------------+
       |        |             |        ^
       |        |        done |        | not done
       +--------+-------------+--------+
```

### State-by-state behavior

| State before rising edge | Action at rising edge | Next state | PC behavior |
|---|---|---|---|
| `FETCH_OPCODE` | `ir <- mem[pc]` | `FETCH_OPERAND` if two-byte, else `EXECUTE` | Hold |
| `FETCH_OPERAND` | `imm <- mem[pc + 1]` | `EXECUTE` | Hold |
| `EXECUTE`, `WAIT_C` | `t_reg <- {ir[4:0], imm}` | `FETCH_OPCODE` | `pc <- pc + 2` |
| `EXECUTE`, WAIT with `D=1` | `wait_remaining <- 0` | `FETCH_OPCODE` | `pc <- pc + 1` |
| `EXECUTE`, WAIT with `D>1` | `wait_remaining <- D - 1` | `WAIT_REMAIN` | Hold |
| `WAIT_REMAIN`, remaining `>1` | `wait_remaining <- wait_remaining - 1` | `WAIT_REMAIN` | Hold |
| `WAIT_REMAIN`, remaining `=1` | `wait_remaining <- 0` | `FETCH_OPCODE` | `pc <- pc + 1` |

**Invariant:** `WAIT_REMAIN` must never be entered with `wait_remaining=0`. If it happens, treat it as a design bug in simulation rather than allowing 13-bit counter underflow.

### Why PC updates on retirement

- During opcode fetch, `pc` identifies the opcode byte.
- During operand fetch, the address is `pc + 1` (computed combinationally); `pc` still identifies the opcode.
- While WAIT runs, both `pc` and `ir` hold steady.
- Once WAIT ends, `pc <- pc + 1`, then the processor fetches the next opcode.
- Later, a taken branch/LOOP can simply substitute its 8-bit target for sequential `pc + instruction_length` on its retirement edge.

This is compatible with the uploaded ISA's PC contract and eliminates any need for branch prediction or pipeline flushes in the non-pipelined implementation.

---

## 6. Minimal control signals

| Signal | Source / asserted when | Effect |
|---|---|---|
| `ir_load` | `state == FETCH_OPCODE` | Capture opcode byte |
| `imm_load` | `state == FETCH_OPERAND` | Capture second byte |
| `is_two_byte` | Combinational opcode/length decoder | Choose next fetch state |
| `wait_c_write` | `state == EXECUTE && legal WAIT_C` | Atomically write 13-bit T |
| `wait_mode` | `ir[4:3]` in a legal WAIT | Select FULL/HALF/QUARTER |
| `wait_start` | Execute a legal WAIT (including D=1) | Load remaining counter with `D-1` |
| `wait_tick` | `state == WAIT_REMAIN` | Decrement remaining counter |
| `pc_write_en` | Exactly when instruction retires | Commit next PC |
| `pc_next` | Sequential address (target mux later) | `pc + 1` or `pc + 2` |
| `retire` | Ordinary EXECUTE / WAIT `D=1` / final WAIT_REMAIN | Combinational final-cycle pulse, sampled at retirement edge |

**Key rule:** `wait_c_write` and `wait_start` are mutually exclusive. `wait_start` is asserted for exactly one cycle per WAIT instruction. Once in `WAIT_REMAIN`, no instruction may re-decode or re-execute.

A separate combinational completion pulse may help verification, but a persistent `wait_done` flag is unnecessary for retaining T or advancing the FSM.

### Instruction-length predecode for future compatibility

The length decoder needs to classify the **memory byte currently being fetched** during `FETCH_OPCODE`, because `ir` only updates at that edge. For the full ISA, the two-byte cases are:

- `WAIT_C` (`000`);
- `PIN_CTRL` (`010`) with bit `[0] = 0` (branch);
- `LOOP` (`011`);
- `MOVE` (`110`) with `[3:2] = 00` or `01` (immediate variants).

All other defined instructions are one byte. Initially, it is acceptable to implement only `WAIT_C` and WAIT, but design the decoder so the other legal instruction lengths can be added without changing the FSM.

---

## 7. Precise WAIT counter convention

Let the 13-bit selected duration be:

```text
case sub_mode
    FULL:     D = T
    HALF:     D = max(13'd1, T >> 1)
    QUARTER:  D = max(13'd1, T >> 2)
    SET_DIR:  no WAIT (future instruction)
endcase
```

**Execution cycle #1 is the `EXECUTE` cycle.**

- If `D=1`: retire on that `EXECUTE` clock edge. No `WAIT_REMAIN` cycle.
- If `D>1`: at that `EXECUTE` edge, load `wait_remaining = D-1` and enter `WAIT_REMAIN`.
- Each `WAIT_REMAIN` cycle consumes exactly one outstanding execution cycle; when the pre-edge count is 1, decrement to zero and retire.

This requires D execution cycles **total**, not D plus an extra load cycle.

### Example: `WAIT FULL` with `T=4`

| Clock edge | Pre-edge state | Action | Counter after edge | PC after edge |
|---:|---|---|---:|---|
| 1 | `FETCH_OPCODE` | Capture WAIT opcode | unchanged | Hold at WAIT address |
| 2 | `EXECUTE` | Execution cycle 1; load `4-1` | 3 | Hold |
| 3 | `WAIT_REMAIN` | Execution cycle 2 | 2 | Hold |
| 4 | `WAIT_REMAIN` | Execution cycle 3 | 1 | Hold |
| 5 | `WAIT_REMAIN` | Execution cycle 4; retire | 0 | +1 |
| 6 | `FETCH_OPCODE` | Begin next instruction | 0 | Hold |

The instruction consumes **5 clocks**: 1 fetch + 4 execution.

### Selected values and edge cases

| T | FULL D | HALF D | QUARTER D |
|---:|---:|---:|---:|
| 1 | 1 | 1 | 1 |
| 2 | 2 | 1 | 1 |
| 3 | 3 | 1 | 1 |
| 4 | 4 | 2 | 1 |
| 7 | 7 | 3 | 1 |
| 434 | 434 | 217 | 108 |
| 8191 | 8191 | 4095 | 2047 |

- Shift truncation is intentional (integer floor division).
- Clamp a shifted result of zero to one.
- Do **not** silently accept `WAIT_C 0`: this is an illegal encoded value under the ISA. The assembler should reject it; simulation should catch it. The ISA has not defined a hardware trap policy.
- Do not count reset cycles or any initial testbench setup cycle as instruction execution.

### Optional area experiment after RTL is correct

Loading `D-1` and decrementing the counter both use subtraction by one. You may investigate **sharing one decrementer** (select `D` during initial load, or `wait_remaining` during subsequent waits, then subtract one). Whether sharing actually improves area/timing is a synthesis question; prioritize the simple RTL first.

---

## 8. Clock-by-clock reference program

### Program and exact machine code

```asm
    WAIT_C 434
    WAIT FULL
    WAIT HALF
    WAIT QUARTER
```

```text
Byte address  Hex  Explanation
0x00          01   WAIT_C, T[12:8] = 00001
0x01          B2   T[7:0]         = 10110010
0x02          20   WAIT FULL
0x03          28   WAIT HALF
0x04          30   WAIT QUARTER
```

Example `$readmemh` content:

```text
01
B2
20
28
30
```

### Golden timing after reset has been deasserted

Clock-edge numbering below begins at **1** for the first active edge executing `FETCH_OPCODE`. Each range is inclusive.

| Rising edge(s) | Instruction | FSM action | Expected PC after final edge |
|---|---|---|---:|
| 1 | WAIT_C | Fetch `0x01` | `0x00` |
| 2 | WAIT_C | Fetch operand `0xB2` | `0x00` |
| 3 | WAIT_C | Commit `T=434`; retire | `0x02` |
| 4 | WAIT FULL | Fetch `0x20` | `0x02` |
| 5 | WAIT FULL | First execution cycle; load 433 | `0x02` |
| 6–438 | WAIT FULL | 433 remaining cycles; retire at 438 | `0x03` |
| 439 | WAIT HALF | Fetch `0x28` | `0x03` |
| 440 | WAIT HALF | First execution cycle; load 216 | `0x03` |
| 441–656 | WAIT HALF | 216 remaining cycles; retire at 656 | `0x04` |
| 657 | WAIT QUARTER | Fetch `0x30` | `0x04` |
| 658 | WAIT QUARTER | First execution cycle; load 107 | `0x04` |
| 659–765 | WAIT QUARTER | 107 remaining cycles; retire at 765 | `0x05` |

**Expected total = `3 + (1+434) + (1+217) + (1+108) = 765` clock cycles.** Immediately after edge 765, the FSM is back in `FETCH_OPCODE` with `PC=0x05`, ready for an additional opcode if one is implemented. For this initial test, end the simulation at that point rather than attempting to execute uninitialized memory.

**Important:** This differs from the previous chat's 768-cycle example because that example counted a separate EXECUTE/load cycle **in addition to** D WAIT cycles. The ISA's actual frozen timing contract makes the correct reference **765**.

---

## 9. Example protocol timing implication

A WAIT instruction does **not** guarantee D clocks between pin transitions, because firmware needs time to fetch and execute surrounding instructions.

For this specified multi-cycle model, assuming each `SHIFT_OUT` is a nonblocking one-byte instruction and no other stalls:

```asm
    SHIFT_OUT R0, P0, SHIFT   ; GPIO changes on EXECUTE retirement
    WAIT FULL                ; 1 fetch + D execution clocks
    SHIFT_OUT R0, P0, SHIFT   ; 1 fetch + 1 execute clock
```

The interval **between SHIFT_OUT retirement edges** is `D + 3` system-clock periods. If a two-byte `LOOP` appears between the WAIT and the next SHIFT_OUT, the interval is `D + 6` clocks (WAIT fetch + D execution + LOOP 3 + next SHIFT_OUT 2).

This example is for an **uninterrupted, non-pipelined execution path**. Future blocking instructions and input synchronization change protocol event timing. Measure GPIO edge-to-edge timing in the testbench when UART/SPI is implemented; do not equate `T` directly with the required external bit period.

---

## 10. Memory assumptions and future integrations

For milestone 1, use a **preloaded, combinational-read ROM model**:

- `instr_addr` drives the current fetch address (`pc` for the opcode, `pc + 1` for the operand).
- `instr_data` is valid combinationally early enough to be sampled at the fetch edge.
- No instruction memory writes are needed for this milestone.

A synchronous-read SRAM can have different address-to-data latency, so the fetch FSM and address timing must be revisited if the memory is changed. **Do not assume this exact two-/three-cycle implementation works unchanged with every SRAM macro.** The final taped-out processor also needs a program-loading path; `$readmemh` is only for simulation.

Future instruction execution uses the **same** fetch FSM and PC control:

- `SET_DIR`: one-byte, one ordinary execution cycle (no counter operation).
- Branch and `LOOP`: PC target selected at retirement; no prediction or flushing.
- `WAIT_PIN` / blocking `DATA_IO`: extend the execution phase until their completion condition, without re-fetching an instruction or repeating side effects.

---

## 11. Two-person ownership and code boundaries — **frozen for this milestone**

We are **not** splitting work by ISA instruction (`WAIT_C` vs. `WAIT`), because both instructions share the same 13-bit T register and processor FSM. That split would produce overlapping modifications and incompatible timing assumptions. Instead, split on a **structural module boundary**:

- **Person A — Instruction sequencer/control:** Owns the PC, opcode/operand registers, fetch/execution FSM, instruction-length decode, and the control strobes sent to the timer. A does **not** implement or modify the 13-bit timing registers or the WAIT arithmetic.
- **Person B — Timing datapath and end-to-end verification:** Owns the T configuration register, FULL/HALF/QUARTER duration selection, remaining counter, terminal-count flags, and the integrated testbench/reference program. B does **not** implement or modify the PC or state machine.

Use these exact paths. The file names, module names, and ports are part of the agreed interface; any changes require both people's approval **before** either edits RTL.

```text
repo/
├── rtl/
│   ├── protocol_core.sv          # A: thin instantiation/wiring top-level
│   ├── instruction_control.sv    # A: PC, IR, IMM, instruction-length decoder, FSM
│   └── wait_timer.sv             # B: T register, duration selection, remaining counter
├── tb/
│   ├── instruction_rom.sv        # A: simulation-only, combinational-read ROM
│   ├── tb_instruction_control.sv # A: isolated control test with a fake timer response
│   ├── tb_wait_timer.sv          # B: isolated timer test with driven control strobes
│   ├── tb_wait_integration.sv    # B: end-to-end DUT/ROM/scoreboard test
│   └── programs/
│       ├── wait_smoke.hex        # B: 01 B2 20 28 30
│       └── wait_boundaries.hex   # B: optional additional directed test image
└── docs/
    └── README_WAIT_WAIT_C_microarchitecture.md   # shared contract; edit by agreed PR only
```

**The program ROM belongs in `tb/`, not synthesizable `rtl/`, for this milestone.** `protocol_core` exposes a generic instruction address/data interface rather than assuming a particular ROM macro; this also makes future firmware loading easier to integrate.

### Assignment matrix

| Deliverable | Owner | What is complete before reunion? |
|---|---|---|
| `rtl/instruction_control.sv` | **A** | Four-state FSM, PC/IR/IMM, legal decode, exact control pulses and retirement |
| `rtl/protocol_core.sv` | **A** | Instantiates the two frozen modules and wires all ports **without new functional logic** |
| `tb/instruction_rom.sv` | **A** | Addressed, combinational-read 8-bit ROM for 256 entries with known test-program loading |
| `tb/tb_instruction_control.sv` | **A** | Proves fetch length, PC retirement behavior, `WAIT_C` strobes and WAIT control sequencing using emulated timer-status inputs |
| `rtl/wait_timer.sv` | **B** | Atomic T update, duration calculation, `D-1` load, countdown and correct status flags |
| `tb/tb_wait_timer.sv` | **B** | Proves T persistence, edge cases, exact remaining counts, reset behavior |
| `tb/tb_wait_integration.sv` and `tb/programs/*.hex` | **B** | Full program and assertions written in advance; run them after pulling A's modules |
| Combined compile, waveforms, regressions, interface signoff | **A+B together** | Both review failures and agree milestone passes |

Person A will have more control-logic work; Person B compensates by owning the full golden-program scoreboard and integration regression. If one person finishes early, review the other person's **PR** rather than independently editing their file.

---

## 12. Frozen module interfaces (signal names, widths, directions)

### 12.1 Public top-level `protocol_core`

```systemverilog
module protocol_core (
    input  logic       clk,
    input  logic       rst,
    input  logic [7:0] instr_data,
    output logic [7:0] instr_addr
);
```

- `clk`: one system clock. All sequential updates occur at the rising edge.
- `rst`: **synchronous active-high** reset; held through a rising edge to reset state. Reset takes precedence over writes/decrements.
- `instr_addr`: combinational instruction-memory read address, determined by Person A.
- `instr_data`: corresponding combinational 8-bit instruction-memory output supplied externally (by the testbench ROM for now).
- There is **no ready/valid/latency signal** on this version of the memory port. It assumes a combinational-read ROM; replacing it with synchronous SRAM requires a new agreement and fetch-timing change.

`protocol_core` consists only of `instruction_control` instance `u_control`, `wait_timer` instance `u_timer`, and named port connections. Do **not** add a second PC, register copy, delay counter, or independent FSM in the top-level.

### 12.2 Person A's module: `instruction_control`

This is the port declaration to implement; it is **not** a complete RTL implementation.

```systemverilog
module instruction_control (
    input  logic        clk,
    input  logic        rst,
    input  logic [7:0]  instr_data,
    output logic [7:0]  instr_addr,

    // Commands to B's wait_timer (combinational control signals).
    output logic        wait_c_write,
    output logic [12:0] t_write_data,
    output logic        wait_start,
    output logic [1:0]  wait_mode,
    output logic        wait_tick,

    // Status from B's wait_timer (combinational observations).
    input  logic        wait_is_single_cycle,
    input  logic        wait_is_last_cycle,

    // Named observation ports; these are not extra state registers.
    output logic [7:0]  pc,
    output logic [7:0]  ir,
    output logic [7:0]  imm,
    output logic [1:0]  state,
    output logic        retire,
    output logic        illegal_instr
);
```

**Person A owns** all sequential state in this module: `pc[7:0]`, `ir[7:0]`, `imm[7:0]`, `state[1:0]`. Person A alone determines when an instruction retires and how PC advances. Never implement a countdown register in A's module.

#### Person A's output/control definitions

| Signal | Driven by A | Exact semantics |
|---|---|---|
| `instr_addr[7:0]` | Fetch address mux | `pc` in `FETCH_OPCODE`, `(pc + 8'd1)` in `FETCH_OPERAND`; in all other states output `pc` (address is ignored) |
| `wait_c_write` | Execute decoder | **Level-high for the one `EXECUTE` cycle** of a valid `WAIT_C` (`IR[7:5]=000`, `{ir[4:0],imm} != 0`); B writes T on its ending edge |
| `t_write_data[12:0]` | Concatenation | Always `{ir[4:0], imm[7:0]}`; used only if `wait_c_write=1` |
| `wait_start` | Execute decoder | **Level-high for the first execution cycle** of a legal WAIT FULL/HALF/QUARTER, including D=1; B loads `wait_remaining <- D-1` on the ending edge |
| `wait_mode[1:0]` | IR field | `ir[4:3]`: `00` FULL, `01` HALF, `10` QUARTER; `11` is **not** a WAIT and is unsupported here |
| `wait_tick` | FSM state | High during **each** `WAIT_REMAIN` cycle; B decrements once at the ending edge, including the terminal cycle |
| `pc[7:0]` | Registered PC | Address of current opcode; changes only at retirement, modulo 256 |
| `ir[7:0]` | Registered opcode byte | Loaded at the end of `FETCH_OPCODE`, holds until next opcode fetch |
| `imm[7:0]` | Registered immediate byte | Loaded at end of `FETCH_OPERAND`, holds otherwise |
| `state[1:0]` | Registered FSM | Encodings frozen below |
| `retire` | Combinational verification pulse | High **during the cycle that ends with instruction retirement**; sampled on its final rising edge, not a sticky done bit |
| `illegal_instr` | Combinational fault indicator | High while `EXECUTE` sees an unsupported/reserved/illegal instruction; execution holds and no architectural write/retire occurs; testbench must `$fatal` |

### 12.3 Person B's module: `wait_timer`

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
    output logic        wait_is_last_cycle,
    output logic [12:0] t_reg,
    output logic [12:0] wait_remaining,
    output logic [12:0] wait_duration
);
```

**Person B owns** sequential state `t_reg[12:0]` and `wait_remaining[12:0]` only. The three remaining outputs are combinational observations. B must **not** add a fetch FSM, PC, or IR, and must not independently determine instruction length or retirement.

#### Person B's status outputs and register behavior

| Signal | Driven by B | Exact semantics |
|---|---|---|
| `wait_duration[12:0]` | Combinational duration selector | FULL = T; HALF = `max(1,T>>1)`; QUARTER = `max(1,T>>2)`; only meaningful for legal `wait_mode` `00`/`01`/`10` |
| `wait_is_single_cycle` | Combinational comparator | `1` iff `wait_duration == 13'd1` (for a legal WAIT mode); **valid in the WAIT `EXECUTE` cycle**, before its rising edge |
| `wait_is_last_cycle` | Combinational comparator | `1` iff `wait_remaining == 13'd1`; **valid in `WAIT_REMAIN`** before the final decrement/retirement edge |
| `t_reg[12:0]` | Persistent register | Reset = `13'd4`; on `wait_c_write` rising edge load `t_write_data`; hold otherwise |
| `wait_remaining[12:0]` | Remaining execution counter | Reset = 0; at `wait_start` edge load `wait_duration - 13'd1`; else at `wait_tick` edge decrement once; hold otherwise |

**Priority at the timer's rising edge:** `rst` > `wait_c_write` for T; `rst` > `wait_start` > `wait_tick` for the remaining counter. Commands `wait_start`, `wait_tick`, and `wait_c_write` are mutually exclusive in valid operation. If both `wait_start` and `wait_tick` assert simultaneously, the sequencer is broken; assert/fail in simulation instead of relying on priority.

For `wait_duration=1`, `wait_start` still asserts for that one EXECUTE cycle and loads zero; **A immediately retires** on the same edge without entering `WAIT_REMAIN`. For D>1, B loads D−1, and A enters `WAIT_REMAIN`. On each subsequent wait-tick edge the remaining counter decrements. At pre-edge `wait_remaining=1`, B asserts `wait_is_last_cycle`, and A retires on that edge.

**Do not register either `wait_is_single_cycle` or `wait_is_last_cycle`:** the controller needs them to make the **same-edge** retirement decision. Registering them would introduce an off-by-one clock. No combinational loop exists because these two flags depend on `t_reg`, `wait_mode`, or `wait_remaining`, not on `wait_start`/`wait_tick`.

### 12.4 Frozen FSM state encodings

Person A uses these 2-bit encodings and uses the same names in RTL to make waveforms straightforward:

```text
2'b00 : FETCH_OPCODE
2'b01 : FETCH_OPERAND
2'b10 : EXECUTE
2'b11 : WAIT_REMAIN
```

`state` is an observation output from A's *existing* state register, **not** an additional pipeline register. No speculative fetch, branch prediction, or flush logic is used.

---

## 13. Shared clock-edge and control handshake contract

This is the section both people must implement **literally**. Commands and status flags are combinational within a cycle; each registered update occurs only at the **end** of that cycle's rising edge. In synthesizable RTL this is normally `always_ff @(posedge clk)` with nonblocking assignments.

| Pre-edge state/opcode | A's outputs high before edge | B's relevant pre-edge status | What happens **at** edge | A's next state |
|---|---|---|---|---|
| `FETCH_OPCODE` | none | ignored | A loads `ir <- instr_data`; PC holds | `FETCH_OPERAND` if current `instr_data` decodes two-byte, else `EXECUTE` |
| `FETCH_OPERAND` | none | ignored | A loads `imm <- instr_data`; PC holds | `EXECUTE` |
| `EXECUTE`, legal `WAIT_C` | `wait_c_write`, `retire` | ignored | B loads T; A increments PC by 2 | `FETCH_OPCODE` |
| `EXECUTE`, legal WAIT, D=1 | `wait_start`, `retire` | `wait_is_single_cycle=1` | B loads 0; A increments PC by 1 | `FETCH_OPCODE` |
| `EXECUTE`, legal WAIT, D>1 | `wait_start` | `wait_is_single_cycle=0` | B loads D−1; A holds PC | `WAIT_REMAIN` |
| `WAIT_REMAIN`, count>1 | `wait_tick` | `wait_is_last_cycle=0` | B decrements count; A holds PC | `WAIT_REMAIN` |
| `WAIT_REMAIN`, count=1 | `wait_tick`, `retire` | `wait_is_last_cycle=1` | B decrements 1→0; A increments PC by 1 | `FETCH_OPCODE` |
| `EXECUTE`, invalid/unsupported | `illegal_instr` | ignored | No T/counter/PC writes; no retirement | Hold in `EXECUTE` until testbench terminates |
| Any state with `rst=1` | A gates `wait_c_write`, `wait_start`, `wait_tick`, `retire`, and `illegal_instr` low | ignored | Both modules synchronously reset their registers | `FETCH_OPCODE` |

**Fetch length predecode:** At the end of `FETCH_OPCODE`, determine 1 vs. 2 bytes from **current `instr_data`**, not from old registered `ir`. Otherwise a two-byte instruction could enter the wrong state. For future-proofing implement the ISA-defined two-byte classifier (WAIT_C; branching PIN_CTRL; LOOP; immediate MOVE/CMP), while marking all non-milestone instructions *unsupported at EXECUTE*.

**Legal WAIT decode:** `ir[7:5]==3'b001`, `ir[4:3]` in `00`,`01`,`10`, and `ir[2:0]==3'b000`. `SET_DIR` (`sub_mode=11`) is **not a WAIT**, and is intentionally unsupported this milestone. Illegal or unsupported bytes must never trigger `wait_start` or `wait_c_write`.

**Legal WAIT_C decode:** `ir[7:5]==3'b000` **and** `{ir[4:0],imm} != 13'd0`. Zero is ISA-illegal; expose `illegal_instr` rather than writing T=0. `wait_c_write` is active only on the valid instruction's final EXECUTE cycle.

**PC update:** No increment in either fetch state; `instr_addr=pc+1` in `FETCH_OPERAND` is only a combinational address selection. PC increments by `8'd1` for retiring WAIT and by `8'd2` for retiring WAIT_C. The PC must remain stable for the entire active wait, including all `WAIT_REMAIN` cycles.

### Control invariants (integration assertions)

1. `wait_c_write`, `wait_start`, and `wait_tick` are one-hot-or-zero in every non-reset cycle; all are low whenever `rst=1`.
2. `wait_start` is asserted on **exactly one cycle per WAIT**; it must not recur during `WAIT_REMAIN`.
3. `wait_tick` is asserted **only** while `state==WAIT_REMAIN`, and `wait_remaining>0` whenever it asserts.
4. `wait_is_single_cycle` is consumed only in the first WAIT EXECUTE cycle; `wait_is_last_cycle` only in `WAIT_REMAIN`.
5. `retire` is asserted **once** per legal instruction, on its final execution cycle, and implies PC changes on the completing edge.
6. `t_reg` changes only on a reset or valid `wait_c_write` edge, and never as a side effect of WAIT.
7. A completed WAIT leaves `wait_remaining=0` and advances PC by **exactly one**.
8. On an illegal/unsupported instruction, `illegal_instr=1`, `retire=0`, neither timer command fires, and the testbench reports an error.
9. When `rst=1` at a rising edge, neither a concurrent retirement nor a timer command overrides the reset values.
10. No combinational feedback path from a controller command to a timer status flag and back to the same command. Status may affect `retire`/next state, but **not** generate `wait_start` or `wait_tick`.

---

## 14. Independent implementation instructions

### Person A: control/frontend deliverables

1. Implement `instruction_control.sv` using the frozen port list in §12.2. Use separate combinational next-state/output decode and synchronous state/register updates, or a clearly equivalent coding style. **Do not** write the timer datapath.
2. Implement `instr_addr` mux (`pc` or `pc+1`) and latch `ir` and `imm` only in their fetch states. `pc` holds until an instruction retires.
3. Implement the 1/2-byte length classifier using the *currently fetched `instr_data`*. Do not classify the instruction length using stale `ir` in `FETCH_OPCODE`.
4. Implement legal WAIT/WAIT_C detection, `wait_c_write`, `t_write_data`, `wait_start`, `wait_mode`, `wait_tick`, and `retire` exactly per §13.
5. Let `wait_is_single_cycle` control the transition from WAIT EXECUTE to either immediate retirement or `WAIT_REMAIN`. Let `wait_is_last_cycle` control terminal retirement from `WAIT_REMAIN`.
6. Implement an `illegal_instr` indication on unsupported/reserved instructions, invalid WAIT arguments, `SET_DIR`, and WAIT_C=0; **do not** count them as NOPs.
7. Implement `protocol_core.sv` as thin named-port instantiations of A's control and B's timer. It can exist before B's code is present, but full integration compilation requires both modules.
8. Implement `tb/instruction_rom.sv` with a **combinational** 256×8 array read and a simulation-only initialization from a provided `.hex` file. Ensure the program path is relative to repository root or explicitly configurable.
9. Implement `tb_instruction_control.sv` with a **stubbed/fake timer response**; exercise both D=1 (`wait_is_single_cycle=1`) and D>1 (`wait_is_single_cycle=0`, later `wait_is_last_cycle=1`) paths. Drive status signals deterministically—never leave these inputs X or floating.
10. Confirm in A's waveform: fetch-address choice, opcode/immediate capture, PC stability during fetch/wait, one-cycle `wait_c_write`, single `wait_start`, repeated `wait_tick`, one retirement. Record test result in the PR.

**A's isolated control test should pass without `wait_timer.sv`.** A does not need B's implementation to exercise its own FSM. A's test should explicitly simulate a fake 3-cycle WAIT remaining phase and demonstrate that the PC advances on the terminal cycle only.

### Person B: timer/datapath + integration tests

1. Implement `wait_timer.sv` using the frozen port list in §12.3. Use a combinational duration selector and status flags, plus synchronous registers for T and remaining cycles. **Do not** write or replicate A's FSM.
2. On reset initialize `t_reg=13'd4`, `wait_remaining=0`. On `wait_c_write`, atomically write all 13 T bits. Otherwise hold T even while counting down.
3. Calculate FULL/HALF/QUARTER by fixed shifts and `max(1, ...)`; avoid a variable barrel shifter. Reserve `wait_mode==2'b11` as unsupported (duration/status output may use a defined benign value, but control must never start a WAIT in this mode).
4. On `wait_start`, load `wait_remaining = wait_duration - 1` (including the `D=1` case). On `wait_tick`, decrement the current positive counter exactly once. Hold remaining count when neither is asserted.
5. Produce **combinational** `wait_is_single_cycle` from duration and `wait_is_last_cycle` from current remaining count. Do not add registers to these flags.
6. Implement `tb_wait_timer.sv` that injects `wait_c_write`, `wait_start`, and `wait_tick` directly. Test T=1,2,3,4,7,434,8191 with all three modes. Check the counter immediately after each rising edge, with proper simulator scheduling.
7. Test back-to-back WAIT sequences and T reconfiguration. Verify that B's timer never writes T during a countdown, that resets work mid-WAIT, and that D=1 loads zero.
8. Create `tb/programs/wait_smoke.hex` with byte values on separate lines: `01`, `B2`, `20`, `28`, `30`.
9. Write `tb_wait_integration.sv` instantiating `protocol_core` and the test ROM by the §12.1 ports. Make a golden-edge scoreboard for §8, a 765-cycle timeout/check, and illegal-instruction detection. The integrated testbench may initially be **unrunnable until A's modules are merged**, but should not require interface rewrites.
10. Confirm timer-unit regressions pass without `instruction_control.sv`, and record the result in B's PR.

**B's isolated timer test should pass without `instruction_control.sv`.** Directly generate correctly spaced `wait_start`/`wait_tick` strobes; assert `wait_is_single_cycle` *before* the D=1 edge and `wait_is_last_cycle` *before* the final WAIT_REMAIN edge.

### Work that should wait for the reunion

- Integration debugging that changes the frozen port contract.
- Structural changes such as removing an FSM state, re-encoding the ISA, or altering the WAIT count convention.
- Adding `SET_DIR`, LOOP, branch execution, protocol GPIO, UART, SPI, or synchronous-SRAM adaptation.
- Premature area optimization (counter/decrementer sharing, clock gating, or pipelining).

---

## 15. GitHub collaboration and merge procedure

The goal is independent changes with minimal merge conflicts and a reproducible integration point. Git branches/PRs also preserve review history even with a two-person team.

### One-time setup (together, before separating)

1. Put **this README** on the default branch (`main`), and treat §§11–13 as the interface contract.
2. Create the directory layout from §11 (empty directories require placeholder files in Git, or may be created when the first real files are committed).
3. Agree that `instruction_control`, `wait_timer`, and `protocol_core` use **exactly** the module/port names of §12. Agree to keep top-level `instr_addr/instr_data` outside the core.
4. Choose one simulator for the first round (e.g., Icarus Verilog with `-g2012`, or Verilator). Note the exact command/tool version in PRs so both run the same tests.
5. Avoid committing generated simulation files (`*.vvp`, `*.vcd`, `obj_dir/`, build logs) unless explicitly needed for a review; put them in `.gitignore`.

### Branches and ownership

**Person A:**

```bash
git switch main
git pull --ff-only
git switch -c feat/instruction-control
# edit only A-owned files
git add rtl/instruction_control.sv rtl/protocol_core.sv         tb/instruction_rom.sv tb/tb_instruction_control.sv
git commit -m "Implement fetch control and processor FSM"
git push -u origin feat/instruction-control
```

**Person B:**

```bash
git switch main
git pull --ff-only
git switch -c feat/wait-timer
# edit only B-owned files
git add rtl/wait_timer.sv tb/tb_wait_timer.sv         tb/tb_wait_integration.sv tb/programs/
git commit -m "Implement WAIT timer and golden regressions"
git push -u origin feat/wait-timer
```

- Open **separate pull requests** targeting `main`. Each PR should include a concise summary, tests executed, and known limitations; the other person reviews it.
- Do **not** have both people modify `protocol_core.sv`, the common README, or the same shared testbench independently during the split.
- If a port/signal definition seems wrong, open a GitHub Issue or PR discussion first; **both must approve the change**, then update the README and both modules in coordinated commits.
- Rebasing/pulling the other's merged branch before integration is fine. Do not force-push `main`, and do not resolve a semantic interface conflict by silently adding adapters or changing a bit width.

### At the reunion: repeatable merge sequence

1. Each demonstrates isolated unit tests **on their own branch**; review signal names, widths, reset, and the truth table in §13.
2. Merge A's reviewed PR, then B's reviewed PR (or reverse if both branches affect different files). Pull latest `main` locally with `git switch main && git pull --ff-only`.
3. Compile `instruction_control.sv`, `wait_timer.sv`, `protocol_core.sv`, the test ROM, and `tb_wait_integration.sv` together. Verify there are **no unresolved modules, extra drivers, implicit nets, or width warnings**.
4. Run `wait_smoke.hex`; verify T=434, all PC transitions, counter behavior, and final PC=0x05 after exactly 765 post-reset instruction edges.
5. Run the boundary/reconfiguration/reset/illegal regression suite. If it fails, create an integration-fix branch/PR; fix the owning source module, not the other person's copy of the logic.
6. Capture a single waveform showing `pc`, `state`, `ir`, `imm`, `t_reg`, `wait_duration`, `wait_remaining`, all timer control strobes, `retire`, and `illegal_instr`.
7. Mark the v1 milestone complete only after both review the waveform and regression results; then tag the passing commit if useful (`wait-v1-rtl`).

### Example simulator commands from repository root

Use the exact top-module names given in this document. These are templates for **after the testbench files exist** (not claims that they already run):

```bash
# A's isolated control test; no wait_timer required
iverilog -g2012 -s tb_instruction_control -o /tmp/tb_control.vvp     rtl/instruction_control.sv tb/tb_instruction_control.sv
vvp /tmp/tb_control.vvp

# B's isolated timer test; no instruction_control required
iverilog -g2012 -s tb_wait_timer -o /tmp/tb_timer.vvp     rtl/wait_timer.sv tb/tb_wait_timer.sv
vvp /tmp/tb_timer.vvp

# Joint integrated regression
iverilog -g2012 -s tb_wait_integration -o /tmp/tb_integ.vvp     rtl/instruction_control.sv rtl/wait_timer.sv rtl/protocol_core.sv     tb/instruction_rom.sv tb/tb_wait_integration.sv
vvp /tmp/tb_integ.vvp
```

If using Verilator instead, establish equivalent commands together. The ROM should load its `.hex` file from a path that works when `vvp` is invoked from the repository root.

---

## 16. Pre-reunion deliverable checklist and shared assumptions

### Both people should agree to these **before** coding

- [ ] ISA bytes unchanged: `WAIT_C` = `000` plus upper 5 T bits, next byte lower 8; WAIT = `001` with FULL/HALF/QUARTER submodes.
- [ ] 2/3-cycle **ordinary** instruction model; WAIT = one fetch plus exactly D execution cycles.
- [ ] The first WAIT `EXECUTE` cycle **already counts as execution cycle 1**; timer therefore loads D−1, not D.
- [ ] PC stays on opcode until retirement; operand read address uses `pc+1` without changing PC.
- [ ] Combinational-read test ROM, single rising-edge clock, synchronous active-high reset; T resets to 4.
- [ ] Control strobes and status flags are **combinational levels in the indicated cycle**, not pulses generated a cycle later.
- [ ] Exact §12 port names/widths/encodings; no unsolicited interface changes.
- [ ] No independent WAIT FSM in timer, no duplicate wait counter in controller.
- [ ] Reserved instructions are signaled via `illegal_instr`, not treated as working operations.
- [ ] Each person owns separate files and tests on a separate branch; integration occurs through reviewed PRs.

### What to bring to the reunion

| Person A brings | Person B brings |
|---|---|
| Control RTL + thin top wired to frozen ports | Timer RTL + standalone unit test |
| Control TB proving both direct and extended retirement paths | Exhaustive directed D=1/2/3, mode and T boundary cases |
| Test ROM and working memory-address waveform | `wait_smoke.hex` and written end-to-end scoreboard |
| A passing unit-test command + sample result | A passing unit-test command + sample result |
| Questions/risks written in PR comments | Questions/risks written in PR comments |

**Practical stop rule:** If a test fails and you're tempted to change a signal's meaning (for example to pulse `wait_start` *after* the EXECUTE edge), stop and propose a contract change instead. Changing one side unilaterally defeats the purpose of parallel implementation.

---

## 17. Boundary-specific integration test plan (in addition to functional tests)

The tests in §18 validate the complete subsystem. The following tests specifically target mistakes that occur when two independently written modules connect:

1. **D=1 same-edge test:** With T=1 and WAIT FULL, assert that `wait_start=1`, `wait_is_single_cycle=1`, `retire=1` **before the same EXECUTE edge**. Immediately after that edge, `PC` increased by 1, state became `FETCH_OPCODE`, and remaining counter is 0.
2. **D=4 handoff test:** At WAIT EXECUTE with T=4, A asserts `wait_start=1`, B reports `wait_is_single_cycle=0`; immediately after the edge, state=`WAIT_REMAIN`, remaining=3, PC unchanged. Three `wait_tick` edges later, remaining=0 and PC increments exactly once.
3. **T write same-edge test:** On `WAIT_C 434` retirement, `wait_c_write=1`, `retire=1` before edge; immediately afterward T=434 and PC increments by 2. WAIT in the following opcode sees **new** T.
4. **Two-byte fetch test:** In FETCH_OPCODE `instr_data=0x01` causes next state FETCH_OPERAND. Fetching `0xB2` at `(pc+1)` does not overwrite `ir`; PC stays 0 until WAIT_C retirement.
5. **Boundary WAIT tests:** D=1 for HALF/QUARTER when T is small; no extra WAIT_REMAIN cycle, no underflow. With T=8191 FULL, there are exactly 8190 WAIT_REMAIN ticks after the first EXECUTE edge.
6. **Reset race test:** Assert `rst=1` so it overlaps `wait_tick` or `wait_c_write` at a rising edge. Both modules reset, and no command's write overrides reset.
7. **Illegal instruction test:** An illegal WAIT operand or `WAIT_C 0` reaches EXECUTE, raises `illegal_instr`, and does not mutate T, remaining, or PC. Scoreboard aborts rather than hanging silently.
8. **No double-retirement test:** Each command pulse can cause at most one retirement per instruction; confirm no next opcode fetch occurs while the WAIT counter is active.

**Timing measurement rule for tests:** `retire` and status signals are evaluated in the **pre-edge** cycle. Registered `pc`, `state`, `t_reg`, and `wait_remaining` change **after** the rising edge (nonblocking assignment update). A testbench should avoid racing the DUT by sampling post-edge values with a clocking block, a later read-only simulation phase, or a small testbench-only delay. Do not introduce physical RTL delays to make tests pass.

---

## 18. Full-system verification/acceptance checklist

### Decode and configuration

- [ ] `WAIT_C 434` fetches two bytes, takes exactly 3 clocks, and loads `T=434` **once** on retirement.
- [ ] T holds its old value throughout both fetch cycles (no partial upper-bit update).
- [ ] Repeated WAIT instructions never modify T.
- [ ] A second legal WAIT_C value replaces the old T atomically.
- [ ] `WAIT_C 0` is rejected by the test generator/assembler or flagged as an illegal program in simulation.

### WAIT timing and sequencing

- [ ] FULL, HALF, and QUARTER compute the D values in the edge-case table.
- [ ] For each legal D, execution consumes **exactly D** active execution cycles and the whole WAIT instruction consumes **exactly `1+D`** cycles.
- [ ] For D=1, instruction retires directly from EXECUTE without entering WAIT_REMAIN.
- [ ] For D>1, the counter loads `D-1` exactly once and monotonically decrements to zero.
- [ ] `pc`, `ir`, and `imm` stay unchanged throughout the active WAIT interval.
- [ ] No next opcode is fetched or executed before WAIT retirement.
- [ ] On the terminal execution edge, PC increments by one **exactly once**.
- [ ] Consecutive FULL/HALF/QUARTER waits work without reprogramming T.
- [ ] The `WAIT_C 434; WAIT FULL; WAIT HALF; WAIT QUARTER` reference reaches `PC=0x05` after exactly **765** instruction clocks (excluding reset).

### Reset and defensive checks

- [ ] Synchronous reset makes `PC=0`, `T=4`, `wait_remaining=0`, state=`FETCH_OPCODE`.
- [ ] Reset while WAIT is active aborts that WAIT and restarts from PC=0; no stale timer state survives.
- [ ] Assert that `WAIT_REMAIN` never has a zero counter before its clock edge.
- [ ] Assert that `wait_c_write` never asserts for an opcode other than legal WAIT_C.
- [ ] Assert that an instruction never retires twice.
- [ ] Flag illegal/reserved instruction encodings rather than silently treating them as legal.

**Waveform signals to inspect:** `clk`, `rst`, `pc`, `instr_addr`, `instr_data`, `ir`, `imm`, `state`, `t_reg`, `D`, `wait_remaining`, `wait_c_write`, `wait_start`, `wait_tick`, `retire`, `illegal_instr`.

---

## 19. Recommended joint implementation order

1. **PC and instruction ROM:** verify `mem[pc]` and `mem[pc+1]` access without incrementing PC during fetch.
2. **FSM and opcode capture:** add `FETCH_OPCODE`, `FETCH_OPERAND`, `EXECUTE`, `WAIT_REMAIN`; validate one- vs two-byte dispatch.
3. **WAIT_C:** assemble the 13-bit T value and verify atomic writes plus `PC+2` retirement.
4. **WAIT duration combinational logic:** implement fixed shifts, three-way selection, and clamp-to-one.
5. **WAIT counter and state transition:** load `D-1` on first execution cycle; consume remaining cycles; retire with `PC+1`.
6. **Directed testbench:** run the 765-cycle golden program, corner cases, reset-in-WAIT, and reconfiguration.
7. **Synthesis inspection:** check for accidental latches, extra shifter hardware, unexpected counters, area, and longest combinational path.
8. **Only then:** introduce other ISA operations through the same fetch/execute framework.

---

## 20. Decisions frozen for milestone 1

| Design question | Frozen answer |
|---|---|
| Pipelined? | **No** |
| One-byte ordinary instruction | **2 cycles** |
| Two-byte ordinary instruction | **3 cycles** |
| WAIT instruction duration | **1 fetch + D execution cycles** |
| FSM | **FETCH_OPCODE / FETCH_OPERAND / EXECUTE / WAIT_REMAIN** |
| PC update | **Only when instruction retires** |
| Operand fetch address | **PC + 1**, computed without writing PC |
| `WAIT_C` T update | **Single 13-bit write on EXECUTE edge** |
| `NEXT` bit / separate WAIT_C FSM | **Not needed** |
| Timing hardware | **Persistent 13-bit T + separate 13-bit remaining counter** |
| Counter convention | **First EXECUTE counts as cycle 1; load D−1; decrement in WAIT_REMAIN** |
| Clocking | **One synchronous system clock** |
| Initial memory | **256 × 8-bit combinational-read simulation ROM** |
| Reset T | **4**, per the ISA |
| Invalid `WAIT_C 0` | **Illegal program; no hardware trap defined** |

**Milestone completion criterion:** The team can explain, from any waveform edge, which instruction is active, why the PC holds or changes, what `T` contains, how many WAIT execution cycles remain, and when the instruction retires. The 765-cycle reference test and boundary tests pass without off-by-one errors.
