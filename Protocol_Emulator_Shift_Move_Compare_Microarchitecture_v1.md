# Protocol Emulator ASIC — SHIFT_IN, SHIFT_OUT, MOVE, and CMP Microarchitecture

**Status:** Proposed implementation contract — review and freeze together before parallel RTL work  
**Milestone:** Add `SHIFT_IN`, `SHIFT_OUT`, `MOV_IMM`, `MOV_REG`, `CMP_IMM`, `CMP_REG`, and `SET_DIR` to the existing non-pipelined core  
**Authors/ownership:** Two-person split defined in §9  
**Existing documents:** `protocol_emulator_ISA_v1_proposed(2).md` and `Protocol_Emulator_WAIT_WAIT_C_Microarchitecture_v1_1.md`

> **Important ISA compatibility note:** The currently uploaded ISA defines equality-only CMP, `eq_flag`, and `BR_EQ`/`BR_NE`. **EQ/LT/GT using `IR[1:0]` is a proposed ISA revision**, not yet part of that file. Both team members must approve §2 and update the ISA document **before** treating the extended encoding as frozen. This implementation proposal otherwise preserves the existing instruction layout, non-pipelined execution timing, and PC-on-retirement policy.

---

## 1. Decisions and design goals

1. **One shared two-entry register file**: R0 and R1, each 8 bits, not separate shift registers for each instruction.
2. **One physical write port** to the register file. All four register-writing operations (`SHIFT_IN`, `SHIFT_OUT SHIFT`, `MOV_IMM`, `MOV_REG`) feed one writeback mux and one write enable. `CMP` never writes a data register.
3. **Two always-readable outputs** (`r0_data`, `r1_data`). No separate read-enable is needed for a two-register flip-flop bank with combinational reads.
4. **One common shift-direction flag**: `shift_dir=0` means RIGHT; `shift_dir=1` means LEFT. The controller owns it, and only `SET_DIR` changes it.
5. **One persistent comparison flag**: `cmp_flag` stores whether the most recent selected EQ/LT/GT comparison evaluated true. Only CMP changes it; reset clears it.
6. **Four GPIO pins** each have their own *registered output value* and *registered output-enable*. `RELEASE` means `oe=0`, not a four-way data-mux output of `'z` inside the core.
7. **Two-flop input synchronizers** for all four raw GPIO input bits. `SHIFT_IN` samples the synchronized value once, at the instruction's retirement edge.
8. **Same existing multicycle FSM**: ordinary 1-byte operations use one `FETCH_OPCODE` cycle and one `EXECUTE` cycle (2 total); immediate operations use `FETCH_OPCODE`, `FETCH_OPERAND`, `EXECUTE` (3 total). No pipeline, forwarding, new state, or branch flush.
9. **No general-purpose ALU**: implement byte selection, fixed-direction shifts, and unsigned equality/ordering compares only.
10. **No multiple ownership of state**: the controller, register bank, GPIO datapath, and compare flag each have exactly one RTL owner.

### What is being corrected from the original brainstorm?

- The proposed **register read enable** is unnecessary unless a later design has a specialized memory/power interface. A single register-select signal plus both R0/R1 combinational outputs is enough.
- A four-way `SHIFT_OUT` conceptual mux is fine for *choosing an operation*, but **high-Z is not a fourth ordinary 0/1 data value**. Set `gpio_out_enable[pin_sel]` to zero and retain output state.
- A pin-select **demultiplexer** can be expressed more cleanly as indexed *per-pin write enables*: only the addressed pin's output-value/enable registers update; the other three pins hold.
- `MOV_REG` and `CMP_REG` do not require an arbitrary 2-read-port RAM. With only R0/R1, the source of `MOV_REG Rn,Rother` is the opposite register, `~reg_sel`.
- Avoid separately assigning R0/R1 in multiple modules. A **single writeback arbiter/mux** must own the write port.

---

## 2. Proposed ISA details — freeze before writing RTL

### 2.1 Existing instruction encodings (unchanged)

| Instruction | Byte 0 fields | Bytes | Behavior |
|---|---|---:|---|
| `SHIFT_IN Rn, Pp` | `[7:5]=100, [4]=reg, [3:2]=pin, [1:0]=00` | 1 | Sample synchronized input and shift into Rn |
| `SHIFT_OUT Rn, Pp, mode` | `[7:5]=101, [4]=reg, [3:2]=pin, [1:0]=mode` | 1 | Drive LOW/HIGH/RELEASE, or emit one register bit and shift |
| `MOV_IMM Rn, imm8` | `[7:5]=110, [4]=reg, [3:2]=00, [1:0]=00` | 2 | Rn ← immediate byte |
| `MOV_REG Rn, Rother` | `[7:5]=110, [4]=reg, [3:2]=10, [1:0]=00` | 1 | Rn ← opposite register |
| `SET_DIR RIGHT/LEFT` | `[7:5]=001, [4:3]=11, [2:1]=00, [0]=direction` | 1 | Update the shared shift-direction flag; **not** a WAIT |

`SHIFT_OUT` modes `[1:0]`: `00` drive 0, `01` drive 1, `10` release (`oe=0`), `11` output endpoint bit + shift once. The `reg` field is ignored for fixed-output modes.

### 2.2 Proposed CMP extension (changes existing ISA)

Keep CMP in the `MOVE` opcode family (`110`), retain the two current submodes, and redefine the low two bits **only for CMP**:

| `[3:2]` | Operation | Bytes | `[1:0]` |
|---|---|---:|---|
| `01` | `CMP_IMM Rn, imm8, op` | 2 | CMP operation |
| `11` | `CMP_REG Rn, Rother, op` | 1 | CMP operation |

| CMP `op=[1:0]` | Condition | Data interpretation |
|---|---|---|
| `00` | `A == B` | 8-bit equality |
| `01` | `A < B` | 8-bit **unsigned** less than |
| `10` | `A > B` | 8-bit **unsigned** greater than |
| `11` | Reserved/illegal | No flag write |

- For `CMP_IMM`: `A=Rn`, `B=IMM`.
- For `CMP_REG`: `A=Rn`, `B=Rother` (the opposite register). **Ordering matters** for LT/GT.
- `CMP` writes `cmp_flag` with the Boolean comparison result at the retiring edge; it does **not** modify R0/R1.
- `MOV` still requires `[1:0]=00`; a nonzero low field in MOV is reserved/illegal.
- `cmp_flag` resets to zero and **holds** across MOV, SHIFT, WAIT, WAIT_C, and SET_DIR.
- Future branches should interpret the one-bit flag as `BR_TRUE` / `BR_FALSE`, or keep the old `BR_EQ` / `BR_NE` names as *assembler aliases only for equality comparisons*. **If retaining old branch mnemonics, document their actual semantics.** The branch encoding can remain unchanged.
- EQ/LT/GT plus true/false branches cover EQ/NE, LT/GE, GT/LE; no signed operations in this milestone.

**Required documentation action:** update the main ISA Markdown with these changes and rename `eq_flag` references consistently. Do not quietly implement a different ISA from the assembler/documentation.

---

## 3. Datapath partition and ownership

```text
                       instruction_control (Person A)
                      [IR, IMM, PC, FSM, shift_dir]
                  EXECUTE strobes + reg/pin/mode/immediate
                                     |
                 +-------------------+--------------------+
                 |                                        |
                 v                                        v
  shift_move_datapath (Person B)                 cmp_datapath (Person A)
  +--------------------------------+            +--------------------------+
  | synchronized GPIO inputs [3:0] |            | A = selected Rn          |
  | GPIO output value [3:0]        |            | B = IMM or Rother        |
  | GPIO output enable [3:0]       |            | EQ / unsigned LT / GT    |
  | shift & MOVE writeback mux     |            | cmp_flag FF              |
  |       +----------------+       |            +-------------^------------+
  |       | data_registers |       |                          |
  |       | R0[7:0],R1[7:0]|-------+-------- r0_data,r1_data --+
  |       | 1 write port   |       |
  |       +----------------+       |
  +--------------------------------+
                                     |
                         protocol_core (Person A)
                      wires modules; physical pads
                   remain a separate wrapper concern
```

**No one creates a second R0/R1**, second `cmp_flag`, or second `shift_dir` register. The top level is wiring, not a place to duplicate state.

### 3.1 Registers / state ownership

| State | Width | Reset | Only writer / owner |
|---|---:|---|---|
| R0, R1 | 8 each | 0 | `data_registers` (B), using its single write port |
| `gpio_out_value` | 4 | 0 | `shift_move_datapath` (B) |
| `gpio_out_enable` | 4 | 0 (pins released) | `shift_move_datapath` (B) |
| GPIO sync stage 1 / stage 2 | 4 each | 0 | `shift_move_datapath` (B) |
| `cmp_flag` | 1 | 0 | `cmp_datapath` (A) |
| `shift_dir` | 1 | RIGHT = 0 | `instruction_control` (A) |
| PC, IR, IMM, FSM | existing | unchanged | `instruction_control` (A) |
| T and WAIT counter | existing | unchanged | `wait_timer` (existing B module) |

---

## 4. Frozen module interfaces

These are *interfaces only*, **not complete implementations**. Port names and cycle semantics are the shared integration contract. The team may rename them once by agreement **before both branches start**, not independently afterward.

### 4.1 `rtl/data_registers.sv` — Person B

```systemverilog
module data_registers (
    input  logic       clk,
    input  logic       rst,
    input  logic       rf_write_en,
    input  logic       rf_write_sel,   // 0 -> R0, 1 -> R1
    input  logic [7:0] rf_write_data,
    output logic [7:0] r0_data,
    output logic [7:0] r1_data
);
```

- Registers are two sets of eight flip-flops. Synchronous active-high reset sets both to `8'h00`.
- `rf_write_en=1` performs **exactly one** write at the rising edge to the selected register; otherwise both hold.
- `r0_data`/`r1_data` expose current register contents **combinationally**, without read-enable.
- Do not add a second register-file write port for each instruction. Do not register the read outputs as a separate pipeline stage.

### 4.2 `rtl/shift_move_datapath.sv` — Person B

```systemverilog
module shift_move_datapath (
    input  logic       clk,
    input  logic       rst,

    // EXECUTE strobes from Person A; legal strobes are one-hot or all zero.
    input  logic       exec_shift_in,
    input  logic       exec_shift_out,
    input  logic       exec_mov_imm,
    input  logic       exec_mov_reg,

    // Decoded instruction fields and persistent shift direction.
    input  logic       reg_sel,
    input  logic [1:0] pin_sel,
    input  logic [1:0] shift_out_mode,
    input  logic       shift_dir,     // 0=RIGHT, 1=LEFT
    input  logic [7:0] imm_data,

    // Pad-facing GPIO interface: input, output value, output enable.
    input  logic [3:0] gpio_in_async,
    output logic [3:0] gpio_out_value,
    output logic [3:0] gpio_out_enable,
    output logic [3:0] gpio_in_sync,   // synchronized pin levels for future PIN_CTRL

    // Always-readable architectural data for CMP and future operations.
    output logic [7:0] r0_data,
    output logic [7:0] r1_data
);
```

Internally **instantiate `data_registers`**. This module owns the selected-register read mux, opposite-register selection, shift-result logic, MOV result selection, and the **one writeback mux** that drives `rf_write_*`.

Input sync: `gpio_sync1` captures `gpio_in_async` on each rising edge and `gpio_sync2` captures previous `gpio_sync1`; expose `gpio_in_sync = gpio_sync2` as a combinational output so future `PIN_CTRL` can reuse the same synchronizer. `SHIFT_IN` uses **pre-edge `gpio_sync2[pin_sel]`** on its retirement edge. Reset both synchronizer stages. Other instructions do not modify synchronization behavior.

**Register write conditions** (exactly one at a time):

| Command | Register write? | Value written to selected Rn |
|---|---|---|
| `exec_shift_in` | Yes | RIGHT: `{sample, Rn[7:1]}`; LEFT: `{Rn[6:0], sample}` |
| `exec_shift_out`, mode `00/01/10` | **No** | N/A |
| `exec_shift_out`, mode `11` | Yes | RIGHT: `{1'b0, Rn[7:1]}`; LEFT: `{Rn[6:0], 1'b0}` |
| `exec_mov_imm` | Yes | `imm_data` |
| `exec_mov_reg` | Yes | `Rother` (opposite register, not selected destination) |
| No command | No | Hold R0/R1 |

`reg_sel=0` means R0 is destination / selected register; `reg_sel=1` means R1. `Rother` is the other register. `SHIFT_OUT` mode `11` uses **the old pre-shift endpoint bit** for the pin update, and shifts the selected register at the same retiring rising edge.

**GPIO updates on `exec_shift_out`** (only addressed `pin_sel` changes):

| `shift_out_mode` | `gpio_out_enable[pin_sel]` | `gpio_out_value[pin_sel]` | Register |
|---|---|---|---|
| `00` | 1 | 0 | Hold |
| `01` | 1 | 1 | Hold |
| `10` | 0 | Hold previous output value (don't care while released) | Hold |
| `11` | 1 | RIGHT: old `Rn[0]`; LEFT: old `Rn[7]` | Shift selected Rn |

All three *unselected* GPIO pins retain their previous `out_value` and `out_enable`. `SHIFT_IN`, MOV, CMP, WAIT, and SET_DIR do not modify GPIO outputs. Output pin levels **persist after** execution until another `SHIFT_OUT` changes them.

**Physical pad rule:** `gpio_out_enable=0` requests release/high-Z at the pad. Never synthesize a four-input data mux containing `'z` *inside* this datapath. A future pad/wrapper can realize tri-state behavior with technology-appropriate I/O cells; I²C requires an external pull-up. The output-value register remains a normal 0/1 flop.

### 4.3 `rtl/cmp_datapath.sv` — Person A

```systemverilog
module cmp_datapath (
    input  logic       clk,
    input  logic       rst,
    input  logic       exec_cmp_imm,
    input  logic       exec_cmp_reg,
    input  logic       reg_sel,
    input  logic [1:0] cmp_op,
    input  logic [7:0] imm_data,
    input  logic [7:0] r0_data,
    input  logic [7:0] r1_data,
    output logic       cmp_flag
);
```

- `A` = selected Rn; `B` = `imm_data` if `exec_cmp_imm`, else opposite Rother if `exec_cmp_reg`.
- `cmp_op`: `00` EQ, `01` unsigned LT, `10` unsigned GT. `11` is illegal and **must not** write flag; control reports illegal instruction.
- At a rising edge with exactly one valid CMP strobe, `cmp_flag <= comparison_result`. Reset clears it; otherwise it **holds**, including during MOV or SHIFT instructions.
- **Do not write R0/R1** here; compare inputs are read-only.
- No subtractor or full ALU is required. Synthesis may implement shared ordering logic; compare area in synthesis rather than making a premature claim.

### 4.4 Additions to existing `instruction_control.sv` — Person A

Preserve all previously frozen WAIT_C/WAIT ports and behavior. Add these **outputs**, which are defined relative to its registered IR/IMM and current FSM state:

```systemverilog
output logic       exec_shift_in,
output logic       exec_shift_out,
output logic       exec_mov_imm,
output logic       exec_mov_reg,
output logic       exec_cmp_imm,
output logic       exec_cmp_reg,
output logic       reg_sel,
output logic [1:0] pin_sel,
output logic [1:0] shift_out_mode,
output logic [1:0] cmp_op,
output logic [7:0] imm_data,
output logic       shift_dir
```

The controller also receives `cmp_flag` as a one-bit **input** for future branches; there is no need to use it for branch execution yet. `shift_dir` is the controller's one-bit stored state. Implement legal SET_DIR so it updates `shift_dir <= IR[0]` on its EXECUTE retirement edge. SET_DIR must **not** trigger `wait_start` or touch the timer.

**Derived signals:**

```text
reg_sel       = IR[4]
pin_sel       = IR[3:2]
shift_out_mode= IR[1:0]
cmp_op        = IR[1:0]   (only meaningful on CMP)
imm_data      = IMM[7:0]
```

The controller may expose these wires continuously; downstream modules use them **only when their corresponding `exec_*` strobe is high**. Every `exec_*` strobe is high **only in the valid instruction's final EXECUTE cycle**, not during FETCH and not while reset is asserted. No strobe may remain high for more than one clock edge per instruction. No two execution strobes are simultaneously high.

**Validity / instruction lengths:**

| Opcode/submode | Extra operand? | Legal fields | EXECUTE result |
|---|---|---|---|
| `SHIFT_IN` (`100`) | No | `[1:0] == 00` | `exec_shift_in` |
| `SHIFT_OUT` (`101`) | No | All 4 output modes | `exec_shift_out` |
| `MOVE 00` = MOV_IMM | **Yes** | `[1:0] == 00` | `exec_mov_imm` |
| `MOVE 01` = CMP_IMM | **Yes** | `[1:0] != 11` | `exec_cmp_imm` |
| `MOVE 10` = MOV_REG | No | `[1:0] == 00` | `exec_mov_reg` |
| `MOVE 11` = CMP_REG | No | `[1:0] != 11` | `exec_cmp_reg` |
| `WAIT/SET_DIR` (`001`, submode `11`) | No | `[2:1] == 00` | write `shift_dir` |

Illegal/reserved instructions **must not emit writes or retire silently**; reuse the original controller's `illegal_instr` mechanism. PC advances by **1 for a legal one-byte instruction** and **2 for MOV_IMM/CMP_IMM**, **at retirement only**. No PC changes during either fetch state. The existing WAIT timing remains unchanged.

### 4.5 Top-level `rtl/protocol_core.sv` — Person A

Retain the existing instruction-memory port (`instr_addr[7:0]`, `instr_data[7:0]`), plus `clk`/`rst`. Extend the module with these *pad-facing logic* ports:

```systemverilog
input  logic [3:0] gpio_in_async,
output logic [3:0] gpio_out_value,
output logic [3:0] gpio_out_enable
```

Keep the `gpio_in_sync[3:0]` signal available as an **internal top-level wire** for future `PIN_CTRL` (it does not need to be an external pin).

Wire `instruction_control`, existing `wait_timer`, `shift_move_datapath`, and `cmp_datapath`; route `r0_data`/`r1_data` from Person B directly to CMP. Route `cmp_flag` back to controller for future branching, but no branch feature is required this milestone. The top must not copy storage, add a second register write driver, or implement internal pad tri-states.

---

## 5. Exact instruction behavior and timing

**All state commits occur at the retiring EXECUTE rising edge**. One-byte instructions take two system clocks; two-byte instructions take three. The previous README's PC-on-retirement and synchronous-reset contract still applies.

| Instruction | Fetches | EXECUTE edge effect | PC after retirement |
|---|---:|---|---|
| `SET_DIR` | 1 | Update `shift_dir` | +1 |
| `SHIFT_IN` | 1 | Read synchronized selected pin and update selected Rn once | +1 |
| `SHIFT_OUT` | 1 | Update selected pin state; shift Rn once only for mode 11 | +1 |
| `MOV_REG` | 1 | Copy other register into selected register | +1 |
| `CMP_REG` | 1 | Update `cmp_flag` based on selected comparison | +1 |
| `MOV_IMM` | 2 | Write IMM to selected register | +2 |
| `CMP_IMM` | 2 | Update `cmp_flag` by comparing selected register vs IMM | +2 |

**No data hazard/forwarding circuit is required** because the processor doesn't overlap instructions. A following CMP reads the prior MOV/SHIFT result from the register bank after that instruction has retired.

### 5.1 Example SHIFT_OUT using R0=8'hA5, RIGHT

Before edge: R0=`1010_0101`, `shift_dir=0`, `exec_shift_out=1`, mode=`11`, P0 selected.  
At retiring edge: P0 output-enable becomes 1, P0 output-value gets **old R0[0]=1**, and R0 becomes `0101_0010` (`0x52`). Other pins/R1 hold. Eight repetitions (with other instructions providing timing) output LSB-first `1,0,1,0,0,1,0,1` and leave R0 at zero.

### 5.2 Example SHIFT_IN using the same LSB-first stream

Starting from R1=`0`, `shift_dir=RIGHT`: apply synchronized samples `1,0,1,0,0,1,0,1` at eight separate `SHIFT_IN` retirement edges. R1 ends as `8'hA5`. **In a pin-level testbench, drive each new raw sample early enough for the two-flop synchronizer**. Sampling the raw pin on the same edge as instruction retirement is *not* valid.

### 5.3 Example CMP with unsigned ordering

R0=`8'hFE` (254), R1=`8'h02` (2):

- `CMP_REG R0,R1,LT` → false (`cmp_flag=0`).
- `CMP_REG R0,R1,GT` → true (`cmp_flag=1`).
- `CMP_REG R1,R0,LT` → true (`cmp_flag=1`).

This catches accidental signed-comparison or operand-order bugs. A subsequent MOV or SHIFT does not clear the comparison flag.

### 5.4 GPIO synchronization and output latency

- The GPIO synchronizers run on **every** core clock independently of the instruction FSM.
- If `gpio_in_async` changes before edge E1: sync stage 1 sees it at E1, sync stage 2 sees it at E2, and a `SHIFT_IN` retiring at E3 can reliably use the new sync-stage-2 value. A testbench must not assume a newly changed raw pin is read on the same edge.
- `SHIFT_OUT` updates registered value/enable on its retirement edge; pin electrical behavior additionally depends on the eventual pad buffer and its delay.
- This implementation is not an edge detector, SPI controller, UART baud generator, or high-speed CDC solution; it follows the ISA's one-sample-per-instruction semantics.

---

## 6. Signal-level agreement / handshake

| Signal(s) | Producer | Consumer | Valid time and meaning |
|---|---|---|---|
| `exec_shift_in` | A control | B shift/move | One EXECUTE retirement cycle; sample one bit into selected Rn |
| `exec_shift_out` | A control | B shift/move | One EXECUTE retirement cycle; update one GPIO output |
| `exec_mov_imm` | A control | B shift/move | One EXECUTE retirement cycle; Rn ← IMM |
| `exec_mov_reg` | A control | B shift/move | One EXECUTE retirement cycle; Rn ← Rother |
| `exec_cmp_imm` | A control | A CMP | One EXECUTE retirement cycle; compare Rn vs IMM |
| `exec_cmp_reg` | A control | A CMP | One EXECUTE retirement cycle; compare Rn vs Rother |
| `reg_sel` | A control | B and A CMP | `IR[4]`, destination/left operand |
| `pin_sel` | A control | B | `IR[3:2]`, selects exactly one P0–P3 |
| `shift_out_mode` | A control | B | `IR[1:0]`, only valid with SHIFT_OUT |
| `cmp_op` | A control | A CMP | `IR[1:0]`, only valid with CMP |
| `imm_data` | A control | B and A CMP | Latched extension byte, valid for immediate instructions |
| `shift_dir` | A control | B | Persistent 0 RIGHT / 1 LEFT; reset 0 |
| `r0_data`, `r1_data` | B register bank | A CMP | Always-readable current byte values |
| `cmp_flag` | A CMP | A control | Persistent result; updated only on legal CMP retirement |
| `gpio_in_async[3:0]` | external pin/testbench | B synchronizer | May be asynchronous; **never** directly sampled by SHIFT_IN |
| `gpio_in_sync[3:0]` | B synchronizer | B SHIFT_IN; future A PIN_CTRL | Stable synchronized input vector; available without adding a second synchronizer |
| `gpio_out_value[3:0]` | B | pad/wrapper/testbench | Registered pin output data |
| `gpio_out_enable[3:0]` | B | pad/wrapper/testbench | Registered 1=drive / 0=release |

**Global edge rule:** The controller asserts instruction `exec_*` signals *before* the final EXECUTE rising edge. Datapath/flag registers sample them on that edge. The controller updates PC and FSM on the **same** edge. The next instruction fetch observes the new architectural state.

**Single writer rule:** There is no global `rf_read_enable` or separate `rf_write_enable` from the control FSM; Person B generates the register-bank's final `rf_write_en/sel/data` from decoded legal execution strobes inside the shift/MOVE datapath. A's control outputs say *what instruction is retiring*, not *how to arbitrate several physical register write ports*.

**Illegal-command rule:** A must never assert two `exec_*` strobes simultaneously, nor assert any during reset or FETCH. If multiple strobes appear, simulations should report an error rather than relying on arbitrary mux priority. Reserved encoding must not corrupt registers or flags.

---

## 7. Suggested decoder and writeback structure

Inside B's `shift_move_datapath`, first derive the **selected** and **other** register values (read-only combinational). Then compute each possible writeback value. A final selection chooses one data value and drives `rf_write_en`, `rf_write_sel`, `rf_write_data` into the *one* register-file write port.

```text
R0 ----+--> selected/other read mux --> SHIFT_IN shift result ----+
R1 ----+                                SHIFT_OUT shift result ---+--> writeback mux --> R0/R1 bank
                                        MOV_REG source ----------+
IMM ----------------------------------> MOV_IMM value -----------+

GPIO raw inputs --> 2-flop sync --> 4:1 input bit select --> SHIFT_IN
selected Rn endpoint + fixed modes --> value/enable update of selected GPIO
```

Avoid creating a dedicated register bank inside each instruction module. Avoid an actual tri-state bus inside the processor. Shift operations are fixed wiring and simple muxing; no general barrel shifter is necessary.

---

## 8. Verification acceptance tests

### 8.1 Person B: standalone register/shift/GPIO tests

- [ ] Reset clears R0/R1, sets every GPIO `oe=0`, and initializes output data/sync stages deterministically.
- [ ] A disabled register write holds both registers; a write to R0 never changes R1 and vice versa.
- [ ] `MOV_IMM R0,8'hA5` writes only R0; `MOV_REG R1,R0` copies A5 into R1 without modifying R0.
- [ ] SHIFT_IN RIGHT and LEFT for all four pin selections; eight samples reconstruct the intended byte, with synchronized input delay accounted for.
- [ ] SHIFT_OUT RIGHT and LEFT emit correct endpoint bit and zero-fill the register on each mode-11 operation.
- [ ] SHIFT_OUT fixed modes drive 0/1/release and **do not modify R0/R1**.
- [ ] RELEASE sets `oe=0`; HIGH sets `oe=1,out=1`; both persist without repeated commands.
- [ ] Updating P2 leaves P0, P1, and P3 output/enable unchanged.
- [ ] A SHIFT_IN does not accidentally modify GPIO outputs; CMP/SET_DIR shouldn't either.
- [ ] Confirm exactly one register write per qualifying retiring edge and none during idle/reset.
- [ ] Test Rn=`8'h00`,`8'h01`,`8'h80`,`8'hA5`,`8'hFF`; confirm old endpoint emitted before shift.
- [ ] Do not sample an async GPIO change directly; check two-flop delay with waveform/test assertions.

### 8.2 Person A: standalone decode/control/CMP tests

- [ ] All six legal MOVE/CMP variants generate exactly the expected execution strobe and instruction length.
- [ ] CMP `00/01/10` handles equality, less-than, and greater-than for both IMM and REG sources.
- [ ] CMP operand order is correct for `reg_sel=0` and `reg_sel=1` (especially LT/GT).
- [ ] Unsigned boundary tests: 0, 1, 127, 128, 254, 255.
- [ ] `cmp_flag` holds across MOV, SHIFT, WAIT, and SET_DIR, and resets to 0.
- [ ] `SET_DIR RIGHT/LEFT` updates one persistent bit and **never starts WAIT**.
- [ ] FETCH versus EXECUTE produces no early or repeated register/flag/GPIO write strobes.
- [ ] Reserved SHIFT_IN bit patterns, reserved CMP `op=11`, invalid MOV low bits, and invalid SET_DIR fields assert `illegal_instr` without a write.
- [ ] PC remains fixed through FETCH states and advances only on final EXECUTE edge: +1 for one-byte operations, +2 for immediate operations.

### 8.3 Shared end-to-end integration tests

- [ ] Run the previous `WAIT_C 434 / WAIT FULL / WAIT HALF / WAIT QUARTER` regression unchanged.
- [ ] Program R0 using MOV_IMM, then SHIFT_OUT it eight times with WAIT/LOOP-like sequencing or explicit repeated instructions; confirm pin transitions and R0 contents.
- [ ] Supply external pin samples and reconstruct a byte in R1 using SHIFT_IN; compare against immediate or R0.
- [ ] Run `MOV_IMM R0, 8'h64; CMP_IMM R0, 8'h64, EQ` and verify flag=1; run LT/GT cases and verify changes.
- [ ] Verify MOV immediately followed by CMP sees the updated register data (no pipeline hazards).
- [ ] Verify changing SET_DIR changes later shifts but doesn't change GPIO/T or initiate WAIT.
- [ ] Confirm no multiple register writes, no unknown (`X`) values post-reset, no double retirement, and no unexpected changes to untouched pins.
- [ ] Full branch execution is not required this milestone; `cmp_flag` must be available for later BR_TRUE/BR_FALSE integration.

### 8.4 Useful opcode bytes for directed test programs

| Assembly | Bytes (hex) | Notes |
|---|---|---|
| `SET_DIR RIGHT` | `38` | Shift direction = 0 |
| `SET_DIR LEFT` | `39` | Shift direction = 1 |
| `SHIFT_IN R0,P0` | `80` | Reserved fields = 0 |
| `SHIFT_IN R1,P2` | `98` | Pin 2, R1 |
| `SHIFT_OUT R0,P0,LOW` | `A0` | Set oe=1, out=0 |
| `SHIFT_OUT R0,P0,HIGH` | `A1` | Set oe=1, out=1 |
| `SHIFT_OUT R0,P0,RELEASE` | `A2` | Set oe=0 |
| `SHIFT_OUT R0,P1,SHIFT` | `A7` | Shift and output on P1 |
| `MOV_IMM R0,8'hA5` | `C0 A5` | 2 bytes |
| `MOV_IMM R1,8'h3C` | `D0 3C` | 2 bytes |
| `MOV_REG R1,R0` | `D8` | 1 byte |
| `CMP_IMM R0,8'hA5,EQ` | `C4 A5` | 2 bytes; proposed CMP bits |
| `CMP_IMM R0,8'h64,LT` | `C5 64` | 2 bytes; proposed CMP bits |
| `CMP_REG R0,R1,GT` | `CE` | 1 byte; proposed CMP bits |

**Check:** `MOV_IMM` and `CMP_IMM` bytes use **the existing opcode plus low two bits**; only CMP's newly assigned `01/10` comparison modes are an ISA extension. Keep the assembler synchronized with this table.

---

## 9. Two-person workload split — work in separate files

The preferred split **preserves the team's earlier ownership**: Person A already owns the instruction control, and Person B already owns timing/datapath work. That is less risky than handing Person B a second piece of the control FSM.

| Task | Owner | Files | Deliverable |
|---|---|---|---|
| **1. Control/status flags** | **Person A** | `rtl/instruction_control.sv` | Decode/validity, fetch length, EXECUTE strobes, persistent `shift_dir`, existing FSM/PC updates |
| **2. Comparison datapath** | **Person A** | `rtl/cmp_datapath.sv`, `tb/tb_cmp_datapath.sv` | `cmp_flag` and EQ/LT/GT comparison, verified independently |
| **3. Register file** | **Person B** | `rtl/data_registers.sv`, `tb/tb_data_registers.sv` | R0/R1 reset, combinational read, exactly one enabled write port |
| **4. SHIFT_IN/SHIFT_OUT datapath** | **Person B** | `rtl/shift_move_datapath.sv`, `tb/tb_shift_move_datapath.sv` | Shared shift/MOV writeback mux, GPIO value/enable registers, synchronized inputs |
| **System hookup** | **Person A** | `rtl/protocol_core.sv`, `tb/tb_shift_move_integration.sv` | Connect modules; instruction-level regression |
| **ISA/doc contract** | **A+B together** | `ISA.md` (team's canonical path), this Markdown | Freeze CMP bits/branch-flag terminology before independent changes |

**Why not split SHIFT_IN to A and SHIFT_OUT to B?** Both need the same R0/R1 write port and shift-direction logic; separate authors can accidentally create multiple writers or duplicate state. A/B split by *state ownership and module boundary*, not by opcodes, avoids these conflicts.

### Before separating — both people must agree

- [ ] CMP bit assignments and unsigned interpretation (§2.2), including flag name `cmp_flag`.
- [ ] R0/R1 are read combinationally; there is only **one** register-file write port.
- [ ] Module and port declarations in §4, including reset polarity and clock edge.
- [ ] `exec_*` are one-cycle retirement strobes, never fetch-stage enables.
- [ ] `shift_dir` is stored **only** in `instruction_control`; it resets RIGHT.
- [ ] `cmp_flag` is stored **only** in `cmp_datapath`; it resets 0.
- [ ] GPIO tri-state is represented as separate `value` and `enable` vectors, not `'z` internal datapath values.
- [ ] `gpio_sync2` drives SHIFT_IN, and testbenches account for input synchronizer latency.
- [ ] Which person integrates: **A owns `protocol_core.sv`**, B reviews all B-side connections.
- [ ] Existing WAIT/WAIT_C ports, FSM encoding, and timing remain unchanged.

### Each person can work independently

**Person A:** Keep temporary fake `r0_data`/`r1_data` inputs in the standalone comparator testbench; no dependency on B's register bank for comparator unit testing. In control testbench, assert each opcode generates only the intended strobe, with correct PC increment and `illegal_instr` behavior. Implement `SET_DIR` in the controller; do not create a second direction flag in CMP or top level.

**Person B:** Stimulate `shift_move_datapath` directly using `exec_*` pulses and manually driven `reg_sel`, `pin_sel`, and `shift_dir`, without needing the instruction decoder. Unit-test the register bank separately first. Include `MOV_IMM` and `MOV_REG` in your writeback mux, although your assigned ISA theme is SHIFT_IN/SHIFT_OUT. Do not modify the controller FSM or comparator flag.

### Suggested build order

1. **Together (short kickoff):** approve ISA change; freeze §4 ports; commit this document / ISA edit to main.
2. **B:** implement and test `data_registers.sv`; then `shift_move_datapath.sv` using direct execution strobes.
3. **A:** add `SET_DIR` and all new decode strobes; independently implement/test `cmp_datapath.sv` with fake register data.
4. **A:** wire `protocol_core.sv` after both unit tests compile; add instruction-level tests.
5. **Together:** run combined regressions, inspect waves, correct interface bugs, and decide whether future DATA_IO writeback needs a new mux input (it will, but not now).

### GitHub workflow

Use one branch per owner and avoid editing each other's RTL while implementing.

```bash
# Person A
git switch main && git pull --ff-only
git switch -c feat/shift-move-control-compare

# Person B
git switch main && git pull --ff-only
git switch -c feat/registers-shift-gpio
```

Each person commits only owned files and unit-test files, opens a PR, and attaches the simulator command/output proving their standalone test passed. After both PRs are reviewed and merged, A completes the top-level wiring and full regression. No force-push to main. If a port width, signal meaning, or timing assumption changes, update this contract and notify both people **before** changing RTL.

Ignore generated `.vvp`, `.vcd`, and `build/` artifacts; commit source `.sv`, test programs, and the Makefile.

---

## 10. Critical stop conditions / known boundaries

- **ISA mismatch:** If the canonical ISA still specifies only `eq_flag`, EQ-only CMP, and BR_EQ/BR_NE, do not claim the EQ/LT/GT RTL conforms to it until updated.
- **Multiple register writers:** If R0 or R1 is assigned in more than `data_registers.sv`, stop and consolidate to one write port.
- **GPIO high-Z mistake:** If logic inside the processor tries to feed `'z` through the shift-result/register write mux, stop; use `gpio_out_enable`.
- **Timing ambiguity:** If any unit asserts a write-enable in FETCH or modifies PC before retirement, it violates the prior WAIT/WAIT_C microarchitecture contract.
- **CDC/sampling ambiguity:** If tests change an asynchronous raw GPIO input at the same edge they expect SHIFT_IN to consume it, the test is invalid for a two-stage synchronizer.
- **MOV/CMP overlap:** If CMP writes Rn or MOV overwrites `cmp_flag`, the implementation is incorrect.
- **Illegal encoding:** If CMP mode `11` or MOV low bits nonzero silently execute, controller validation is incomplete.

**Milestone sign-off:** Both independent unit suites pass; SET_DIR, shifts, MOVE, and CMP retire on the specified edges; integration preserves the old timer regression; R0/R1 and GPIO state changes occur exactly once on legal retirement edges; `cmp_flag` matches the selected unsigned comparison and persists until the next CMP/reset.
