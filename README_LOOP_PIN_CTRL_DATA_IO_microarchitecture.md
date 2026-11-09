# Protocol Emulator ASIC — `LOOP`, `PIN_CTRL`, and `DATA_IO` Microarchitecture

**Status:** LOOP and all legal PIN_CTRL modes are implemented in the controller, with absolute target loading in the PC. Functional verification and top-level integration are deferred. DATA_IO, mailboxes, and host UART remain proposals; no execution logic is implemented for DATA_IO.
**ISA reference:** `protocol_emulator_ISA_v1_proposed.md` (current EQ/LT/GT encoding reference)
**Previous milestone:** `Protocol_Emulator_WAIT_WAIT_C_Microarchitecture_v1_1.md`
**Processor:** 8-bit byte-addressed PC, 256 × 8 instruction memory, non-pipelined multicycle execution, R0/R1 (8 bits)

> **Important:** This document retains the *existing* ISA and instruction-retirement convention. It does not redefine the already-implemented PC, IR/IMM, register file, or WAIT timer. In the evolving RTL repository, keep the existing file/module names (e.g. `pc.sv`, `pc_sel`), rather than creating duplicate state solely to match names in this proposal. Interface names below are a **proposed integration contract** to agree on before parallel coding.

## 1. Goal and division of responsibility

Implement three instruction families:

- **`LOOP` (`011`)** — a single hardware counter for bottom-tested loops.
- **`PIN_CTRL` (`010`)** — `WAIT_PIN` low/high/rising/falling, `BRANCH_PIN` low/high, `JMP`, `BR_TRUE`, and `BR_FALSE`.
- **`DATA_IO` (`111`)** — blocking `PULL` and `PUSH` between R0/R1 and two host mailboxes.

### Recommended two-person split

| Owner | Functional scope | Owns/changes | Does **not** own |
|---|---|---|---|
| **Person A — control flow** | `LOOP`, all `PIN_CTRL` submodes, PC-target selection, instruction-length decode, loop abort on taken branch, multi-cycle `WAIT_PIN` handling | Existing instruction-controller/FSM and PC integration, loop state and pin-wait state, synchronizer interface, A's standalone tests | Host mailbox registers, host UART RX/TX |
| **Person B — data movement / host I/O** | Two one-entry 8-bit mailboxes, `PULL`/`PUSH` ready/valid transaction logic, host test drivers, optional dedicated host UART RX/TX | `data_mailboxes.sv`, optionally `host_uart_rx.sv`, `host_uart_tx.sv`, B's standalone tests | PC, instruction-fetch FSM and opcode decoding; mailbox modules must reuse the existing B-owned R0/R1 bank |
| **A + B together** | Wire the controller's `DATA_IO` request to B's handshake; register-file writeback; full-program regression; optional UART demo | Core/top-level connection changes agreed during integration | Independent simultaneous edits to the same controller/top-level files |

**Why this split?** `LOOP` and `PIN_CTRL` both redirect PC and belong with the existing sequencer. `DATA_IO` has a clean external interface and substantial independently testable logic. Person B implements the *storage and handshake*, while Person A makes the sequencer wait for a successful handshake. This avoids both persons editing the instruction controller simultaneously.

**Milestone order:** (1) A and B freeze signals; (2) A and B implement and test independently; (3) integrate mailboxes with a testbench acting as host; (4) optionally connect a dedicated host UART. Do not block core verification on PuTTY bring-up.

---

## 2. Existing processor timing contract

The prior WAIT milestone established:

1. `FETCH`: fetch `mem[PC]` into `IR`; PC **holds**.
2. If two bytes: `FETCH_OPERAND`: fetch `mem[PC+1]` into `IMM`; PC **holds**.
3. `EXECUTE`: perform the operation; the instruction updates PC **only upon retirement**.
4. A nonblocking one-byte instruction costs **2 clocks total** (fetch + execute); a nonblocking two-byte instruction costs **3 clocks total** (fetch opcode + fetch operand + execute).
5. A blocking instruction can remain in `EXECUTE` for extra clocks. Its side effects must occur **once**, on successful completion; PC must hold while blocked.
6. Preserve the existing `WAIT_REMAIN` state for timer waits; `WAIT_PIN` and `DATA_IO` can extend `EXECUTE` without borrowing the timer's countdown.

**PC sources:** ordinary fall-through `PC + instruction_length`; taken `PIN_CTRL` branch or active `LOOP` repetition will use `IMM[7:0]` (absolute **byte** address). Keep one PC register. The controller selects hold, +1, +2, or `PC_TARGET` (`11`) using `pc_sel`; `pc.pc_target` must be wired directly to saved IMM. No speculative fetch, flush or branch prediction is required.

### Two-byte predecode (from the ISA)

Two-byte instructions are `WAIT_C (000)`, `PIN_CTRL (010)` **when `IR[0]=0`**, `LOOP (011)`, and `MOVE (110)` with submode `00`/`01`. `WAIT_PIN` uses one byte; `BRANCH_PIN`/`JMP`/flag branches use two. Decode length from the newly fetched opcode byte, **not** from the previous `IR` value.

### Shared PC-control truth table

| Executing instruction | Condition | Retire this edge? | Next PC | Loop state |
|---|---|---:|---|---|
| Ordinary 1-byte | completed | Yes | `PC + 1` | Hold |
| Ordinary 2-byte | completed | Yes | `PC + 2` | Hold |
| `LOOP` | repeat | Yes | `IMM` | Set/decrement as described below |
| `LOOP` | finished | Yes | `PC + 2` | Clear |
| `PIN_CTRL` branch | taken | Yes | `IMM` | **Clear active loop** |
| `PIN_CTRL` branch | not taken | Yes | `PC + 2` | Hold |
| `WAIT_PIN` | condition unmet | No | Hold | Hold |
| `WAIT_PIN` | condition met | Yes | `PC + 1` | Hold |
| `PULL`/`PUSH` | mailbox not ready | No | Hold | Hold |
| `PULL`/`PUSH` | handshake succeeds | Yes | `PC + 1` | Hold |

All arithmetic is 8-bit; assembler must prevent an instruction crossing memory end or a target pointing into an immediate byte. The PC changes on the **ending rising edge** of the completion cycle; current RTL has no separate `retire` output.

---

## 3. `LOOP` microarchitecture — Person A

### 3.1 ISA encoding and semantics

```text
Byte 0:  [7:5] = 3'b011   [4:0] = encoded_count
Byte 1:  [7:0] = absolute byte address of the first instruction of the body

N = (encoded_count == 0) ? 32 : encoded_count  // 1 through 32
```

This is a **bottom-of-loop** instruction: the body has **already executed once** by the time `LOOP` first runs. `N` is the **total** body-iteration count, not an additional-repeat count.

### 3.2 Required state

| Register | Width | Reset | Role |
|---|---:|---|---|
| `loop_active` | 1 | 0 | A previous encounter initialized this live loop |
| `loop_remaining` | 5 | 0 | Number of **additional body executions** still required |

No loop start-address register is required: the target is supplied by `IMM` whenever `LOOP` executes. There is **one active loop**, no nesting and no early exit without a branch clearing the loop state. Firmware/assembler must honor this constraint; an active counter must not be reused by an unrelated `LOOP` instruction.

### 3.3 Combinational decision and sequential update

On an `EXECUTE` clock of a legal `LOOP` instruction:

```text
if (!loop_active) {
    if (N == 1) {
        loop_active    <- 0;
        loop_remaining <- 0;
        next_pc        <- PC + 2;
    } else {
        loop_active    <- 1;
        loop_remaining <- N - 1;    // fits in 5 bits, even N=32
        next_pc        <- IMM;      // repeat the body
    }
} else {
    if (loop_remaining > 1) {
        loop_remaining <- loop_remaining - 1;
        loop_active    <- 1;
        next_pc        <- IMM;
    } else { // loop_remaining == 1 in a legal active loop
        loop_remaining <- 0;
        loop_active    <- 0;
        next_pc        <- PC + 2;
    }
}
```

Commit these registers and PC **once on the LOOP retirement edge**. A `LOOP` always retires in its first `EXECUTE` cycle (3 clocks total including both fetches). The compare and decrement are only 5 bits wide.

**Taken non-LOOP branches:** set `loop_active=0`, `loop_remaining=0` on that **same** branch-retirement edge. An untaken conditional branch does not clear either register. A taken unconditional `JMP` also clears them. This applies even if the target happens to equal the fall-through address.

### 3.4 Example: `LOOP 3, 0x20` at address `0x24`

| Visit to `LOOP` | Before | At retirement | PC after retirement |
|---|---|---|---|
| First (body already executed once) | inactive | set active, remaining=2 | `0x20` |
| Second | active, remaining=2 | decrement to 1 | `0x20` |
| Third | active, remaining=1 | clear active, remaining=0 | `0x26` |

Body executes **exactly three times**. For `LOOP 1`, the first visit immediately falls through. Encoded zero means 32 **total** passes; the initial `remaining` value is 31.

### 3.5 Suggested RTL boundary

Person A can keep these 6 state bits in the existing controller or place them in an A-owned `loop_unit.sv`. Either way, **do not add a second PC**.

Suggested internal control signals: `loop_execute`, `loop_encoded_count[4:0]`, `loop_target[7:0]`, `branch_taken`, `loop_jump`, `loop_next_pc[7:0]`, `loop_active`, `loop_remaining[4:0]`. If extracted into a module, its outputs determining the next PC must be **combinational before** the retirement edge; a registered `loop_done` pulse would introduce an unintended cycle.

### 3.6 Unit tests

- `N=1`, `N=2`, `N=3`, `N=31`, encoded `N=0` (32); check **total** body visits.
- Loop target different from current PC; check byte addresses and `PC+2` fall-through.
- Taken `BRANCH_PIN`, `JMP`, `BR_TRUE`, `BR_FALSE` abort active loop; untaken branch leaves it intact.
- Reset mid-loop clears state; no PC update occurs before retirement.
- Verify `LOOP` consumes exactly three clocks per encounter, with no extra countdown cycle.

---

## 4. `PIN_CTRL` microarchitecture — Person A

### 4.1 Encoding

```text
IR[7:5] = 3'b010
IR[4:3] = pin[1:0]  // P0 through P3, except special submodes
IR[2:1] = condition
IR[0]   = mode

mode=1: WAIT_PIN, 1 byte, no IMM
  condition=00: wait until synchronized pin is LOW
  condition=01: wait until synchronized pin is HIGH
  condition=10: wait for RISING edge while armed
  condition=11: wait for FALLING edge while armed

mode=0: branch, 2 bytes, IMM is absolute target
  condition=00: BRANCH_PIN pin, LOW, IMM
  condition=01: BRANCH_PIN pin, HIGH, IMM
  condition=10: JMP IMM; pin bits ignored
  condition=11: IR[4] must be 0; IR[3]=0 -> BR_TRUE IMM;
                              IR[3]=1 -> BR_FALSE IMM
```

**Reserved:** `mode=0`, `condition=11`, `IR[4]=1`. The decoder rejects this encoding; current reserved instructions stall without writes and have no trap/fault output; do not silently treat it as `BR_FALSE` or `JMP`.

### 4.2 Pin input datapath

```text
external P0..P3 -> 2-flop synchronizer for each pin -> pin_sync[3:0]
                                              |
                                              v
                                pin select mux (IR[4:3])
                                              |
                                   selected_pin_sync
                                              |
                 +----------------------------+---------------------+
                 |                                                  |
              level compare                                  edge detector
          low/high condition                                arm + prev sample
                 |                                                  |
                 +----------------------------+---------------------+
                                              |
                                   WAIT completion / branch taken
```

Sample only synchronized **input** signals. A released high-Z output does not create a logical `Z` condition for the instruction; input is read as 0/1 according to the physical level/pull-up. Use a shared synchronizer from the GPIO subsystem if one already exists. **Do not place a second independent 2-flop synchronizer in `PIN_CTRL`**.

**Startup validity:** Connect `shift_datapath.gpio_sync_valid` to the controller input of the same name. It resets low and becomes high alongside the second post-reset synchronized sample. WAIT_PIN must neither evaluate a level nor arm an edge baseline until valid; BRANCH_PIN also holds until valid. JMP and comparison-flag branches ignore this signal. The first instruction can therefore require an extra startup execution clock; ordinary timing below assumes valid samples are already available. Validity tracks reset recovery, not detection or elimination of metastability.

### 4.3 Branch execution (2-byte, one EXECUTE cycle)

Combinational branch-taken equations using the value visible **before** the EXECUTE retirement edge:

```text
BR_LOW:  taken = (selected_pin_sync == 1'b0)
BR_HIGH: taken = (selected_pin_sync == 1'b1)
JMP:     taken = 1'b1
BR_TRUE:   taken = cmp_flag
BR_FALSE:   taken = !cmp_flag
```

`cmp_flag` is the persistent Boolean EQ/unsigned LT/unsigned GT result last written by `cmp_datapath` on CMP; MOV does not modify it. It is not an equality-only flag. For `BR_TRUE` and `BR_FALSE`, ignore pin data. On taken branch: `next_pc=IMM` **and clear loop state**. Otherwise `next_pc=PC+2`. Branches finish in **3 clocks total**.

### 4.4 Level waits (1 byte)

During the first and every subsequent `EXECUTE` cycle:

- LOW: finish when `selected_pin_sync==0`.
- HIGH: finish when `selected_pin_sync==1`.
- Otherwise hold `IR`, `PC`, `EXECUTE`, and all unrelated architectural state.
- A condition already satisfied on the first EXECUTE cycle retires at that cycle's edge (**2 total clocks** including fetch).

### 4.5 Edge waits (1 byte; precise arming rule)

Avoid the common bug of noticing an edge that happened **before** the instruction began executing.

Add to A's controller or A-owned pin-wait logic:

- `edge_armed` (1 bit), reset 0.
- `edge_prev` (1 bit), reset value unimportant while unarmed.

Suggested cycle behavior:

1. On **first EXECUTE cycle** of a rising/falling wait (`edge_armed=0`), latch `edge_prev <- selected_pin_sync`, set `edge_armed <- 1`, and **do not retire**. This establishes a baseline only after the instruction is armed.
2. On each **later EXECUTE cycle**, compute `rise = !edge_prev && selected_pin_sync`, `fall = edge_prev && !selected_pin_sync` from the currently synchronized sample and stored sample.
3. If the requested transition occurs, retire **on that edge** and clear `edge_armed`; otherwise update `edge_prev <- selected_pin_sync`, hold PC/IR and remain in `EXECUTE`.
4. On reset or retirement of any `WAIT_PIN`, clear `edge_armed` so the next edge wait starts with a new baseline. If the design has an execution-abort mechanism, clear it there too.

This intentionally requires at least **two EXECUTE cycles** for an edge wait (one to arm, one to detect), while a level wait may finish in one. Edge transitions before arming, or too short to survive synchronizing, can be missed; **there is no event queue** in v1. Account for the two-flop synchronization latency in timing tests.

### 4.6 Unit tests

- All 4 pins and all 4 WAIT conditions; immediately satisfied level and delayed level.
- Rising and falling edge **after** arming succeed; a transition **before** arming alone does not satisfy the wait.
- `BR_LOW`/`BR_HIGH` both taken and not taken; `JMP` independent of pin.
- True and false branches for `cmp_flag=0/1`; no unwanted flag modifications.
- Reserved encoding is illegal; correct one-byte/two-byte decode and PC fall-through.
- Hold PC/IR while waiting, no repeated side effects, loop clears only for **taken** branches.

---

## 5. `DATA_IO` microarchitecture — Person B (mailboxes), Person A (sequencing)

### 5.1 ISA encoding and behavior

```text
IR[7:5] = 3'b111
IR[4]   = register select (0: R0, 1: R1)
IR[3]   = operation (0: PULL, 1: PUSH)
IR[2:0] = 3'b000 (all other values reserved)
```

- **`PULL Rn`:** when input mailbox contains a byte, transfer it to Rn and consume that **one** mailbox entry; otherwise block at the same `EXECUTE` instruction.
- **`PUSH Rn`:** when output mailbox has room, copy Rn to the mailbox and mark it valid; otherwise block.
- A successful one-byte instruction takes **2 clocks total** if its mailbox is immediately ready; longer if blocked.
- No external pin shifting happens as part of `DATA_IO`. `SHIFT_IN` builds bytes in registers; `PUSH` exports them. `PULL` imports bytes; `SHIFT_OUT` can serialize them.

### 5.2 First milestone: two single-entry mailboxes

**Host-to-engine (input):** `in_data[7:0]` + `in_valid`. Host writes; processor's `PULL` consumes.  
**Engine-to-host (output):** `out_data[7:0]` + `out_valid`. Processor's `PUSH` writes; host consumes.

```text
PC terminal / Python script
          | host UART RX (optional hardware later)
          v
  +---------------------+      PULL Rn       +----------+
  | input mailbox       | -----------------> | R0 / R1  |
  | byte[7:0] + valid   |                    +----------+
  +---------------------+                         |
                                                  | PUSH Rn
                                                  v
  +---------------------+ <------------------------+
  | output mailbox      |
  | byte[7:0] + valid   |
  +---------------------+
          |
          v
    host UART TX (optional hardware later) -> PC terminal / Python

Separate P0..P3 protocol GPIOs -> SHIFT_IN/SHIFT_OUT/WAIT_PIN
```

The FIFO **depth is not ISA-visible**; we can replace the one-entry mailboxes with deeper FIFOs later without changing instructions. For this prototype the single-entry version is smaller and easier to verify.

### 5.3 Proposed core/host handshake contract

Signals use **ready/valid** rules: a transfer occurs on a rising edge **only when valid && ready**. A producer must hold its `data` and `valid` until accepted. Synchronous reset clears both mailbox valid bits.

| Signal | Direction relative to `data_mailboxes` | Meaning |
|---|---|---|
| `host_in_data[7:0]` | in | Byte offered by testbench/host RX wrapper |
| `host_in_valid` | in | Host is offering a byte |
| `host_in_ready` | out | Input mailbox empty; host can write |
| `host_out_data[7:0]` | out | Stored outgoing byte |
| `host_out_valid` | out | Output mailbox contains an outgoing byte |
| `host_out_ready` | in | Host consumer can accept outgoing byte |
| `core_pull_valid` | out | Input mailbox has a byte ready for `PULL` |
| `core_pull_data[7:0]` | out | Input byte, stable while valid and unconsumed |
| `core_pull_ready` | in | Controller commits a PULL on this edge |
| `core_push_data[7:0]` | in | Selected register's byte to transmit |
| `core_push_valid` | in | Controller requests a PUSH while executing it |
| `core_push_ready` | out | Output mailbox can accept a byte |

`core_pull_valid` and `host_in_ready` are observations from mailbox occupancy; `core_push_ready` and `host_out_valid` similarly. For simplicity, use:

```text
host_in_ready  = !in_valid
core_pull_valid = in_valid
core_push_ready = !out_valid
host_out_valid  = out_valid
```

This version deliberately **does not accept simultaneous replace-in-place on a full entry**. A full mailbox can be emptied on an edge and refilled on a later edge. More aggressive throughput optimizations should be deferred.

**Update rules at each rising edge:**

```text
host_input_accept  = host_in_valid  && host_in_ready
core_input_consume = core_pull_valid && core_pull_ready
core_output_accept = core_push_valid && core_push_ready
host_output_accept = host_out_valid  && host_out_ready

if (host_input_accept):  in_data <- host_in_data;  in_valid <- 1
else if (core_input_consume):                       in_valid <- 0

if (core_output_accept): out_data <- core_push_data; out_valid <- 1
else if (host_output_accept):                        out_valid <- 0
```

Use one sequential `always_ff` for each mailbox or an equivalent clear-priority structure; never write multiple procedural drivers to `valid`. Reset takes priority over all transfers. With the simple `ready = !valid` convention, a simultaneous input-write and input-consume cannot both occur, and a simultaneous output-write and output-consume cannot both occur.

### 5.4 Controller/processor semantics (Person A integrates after B's block is ready)

**PULL:** while `EXECUTE && DATA_IO && mode==PULL`, assert `core_pull_ready=1`. If `core_pull_valid=0`, **do not retire**; no RF write. If `core_pull_valid=1`, on that edge (a) assert write-enable for `IR[4]`-selected R0/R1, (b) write `core_pull_data`, (c) consume the input mailbox, (d) retire and advance `PC+1`. These are all effects of **one handshake edge**.

**PUSH:** while `EXECUTE && DATA_IO && mode==PUSH`, drive `core_push_data` from the IR-selected register and assert `core_push_valid=1`. If `core_push_ready=0`, **do not retire** or alter the register; hold register data stable while blocked. If ready, write output mailbox and retire on the **same edge** with `PC+1`.

Core datapath must use **the existing R0/R1 storage**. Mailboxes must not instantiate a second copy of the register file. `PULL` will share register-file write arbitration with `MOVE`/`SHIFT_IN`/`SHIFT_OUT` (only one instruction executes at a time). A `PUSH` reads the selected register and does not change it. Illegal `IR[2:0]` must not trigger any mailbox or RF side effect.

**No repeated transfers:** as soon as a PULL/PUSH succeeds, the FSM leaves EXECUTE and the request deasserts. Do not create a sticky `data_io_done` that lasts an extra EXECUTE clock. The mailboxes see exactly one clock of valid transaction per retiring `DATA_IO` instruction.

### 5.5 Example: dynamic UART TX and RX

**Transmitting arbitrary bytes:**

1. PC/testbench provides `0x41` to the dedicated host UART RX (or directly drives `host_in_data/valid` in RTL simulation).
2. Host RX logic stores it in the input mailbox (`in_valid=1`).
3. Core runs `PULL R0`: R0 gets `0x41`; input mailbox becomes empty.
4. Firmware uses `SHIFT_OUT`, `WAIT`, `LOOP` on a **protocol GPIO** to serialize the UART bits to an external DUT.

**Reporting received bytes:**

1. Firmware uses `WAIT_PIN`, `WAIT`, `SHIFT_IN` to capture a byte from an external DUT into R1.
2. Core runs `PUSH R1`: output mailbox becomes valid with R1's byte.
3. Dedicated host UART TX (or RTL host testbench) consumes it and sends the byte to PC.
4. PuTTY shows printable ASCII (e.g. `0x41` appears as `A`). For arbitrary binary values, use Python `pyserial` and inspect hex bytes; PuTTY is not a binary checker.

**Two different UARTs:** The **host UART** is hardwired communication/control hardware; the **emulated UART** is firmware plus generic protocol GPIO. Do **not** connect the DUT's protocol RX pin directly to the host UART RX, or the programmable processor will be bypassed.

### 5.6 Host UART: integration option, not a blocker for RTL milestone

An actual taped-out chip requires a **physical host interface**; a testbench-supplied byte is not a standalone hardware input mechanism. Recommend a dedicated host UART RX and TX pair for demonstration because a USB-to-UART adapter and PuTTY/Python are simple to use.

- `host_uart_rx.sv`: configurable/specified baud divider, UART 8N1 reception, `rx_done` pulse and `rx_data`; checks framing. Adapter signal is separate from the four emulated GPIOs.
- `host_uart_tx.sv`: accepts an outgoing byte when idle, sends UART 8N1; `tx_ready` low while busy. Connect to output mailbox `host_out_valid/data` and consume on `tx_ready && valid`.
- **Important flow-control limitation:** a real UART RX cannot pause the remote sender in the middle of a byte. If the single-entry input mailbox is full when a new byte completes, data may be lost. Either (a) pace host bytes in Python, (b) use a deeper input FIFO and detect overrun, or (c) add an explicit host acknowledgment/flow-control protocol. Mark overflow as a **fault**, not silently successful delivery.
- For the first demo, use a known baud such as 115200 8N1 **only after verifying the clock/baud divider**. A host UART's 115200 baud is independent of the waveform rate of the emulated protocol; continuous host throughput cannot exceed the serial link capacity.
- Program-image loading is still **separate and unresolved**: `$readmemh` is simulation-only. Later, a UART command protocol may multiplex program loading and payload traffic (e.g. LOAD/RUN/PAYLOAD commands), but arbitrary raw bytes cannot be safely distinguished from loader commands without framing/mode control.

### 5.7 DATA_IO unit tests

- Start with both mailboxes invalid after reset; `PULL` stalls on empty; `PUSH` retires into empty output.
- `PULL R0` and `PULL R1` each consume **one** queued byte and update only the selected register.
- `PUSH R0` and `PUSH R1` preserve registers and create exactly one outbound byte.
- `PUSH` stalls when full; drains only after host handshake; on retry it emits once.
- Test consecutive PULL and PUSH instructions, host send/read handshake, reset mid-stall.
- Assert `PC` and `IR` hold while blocked; no early writeback or double transfer.
- Test reserved low bits, unrelated register writes, output byte ordering and host UART backpressure.
- If UART RX is installed, test bytes arriving while mailbox full and verify a deterministic overrun indication (or the documented host pacing constraint).

---

## 6. Integration interfaces and ownership freeze

### 6.1 Existing sequencer → shared PC

Use the separate `pc.sv` module with its Step 7 `pc_sel` interface:

```systemverilog
// Controller output: PC_HOLD except when a supported instruction completes.
logic [1:0] pc_sel;
logic [7:0] pc_value;

pc u_pc (
    .clk    (clk),
    .reset  (rst),
    .pc_sel (pc_sel),
    .pc_target (imm), // saved operand from inst_fetch
    .pc     (pc_value)
);
```

The instruction-fetch block reads `pc_value`, owns the single IR/IMM register pair, and selects the instruction address (PC or PC+1). The controller reads live `inst` for length decoding and saved `ir` for execution, drives `ir_load`/`imm_load`, and selects `PC_PLUS_1` or `PC_PLUS_2` only on the final execution cycle. Integration wiring forwards saved instruction data to the datapaths and provides `wait_c_nonzero=|t_write_data` to the controller for WAIT_C legality. The controller has no IMM data input. The PC block owns PC arithmetic and storage; the controller contains no PC, IR, or IMM registers. Selector `PC_TARGET` (`2'b11`) now loads the 8-bit `pc_target` input. Connect saved IMM directly to that input. The controller also now requires `gpio_in_sync[3:0]` from the existing shift datapath and `cmp_flag` from the comparator; its loop and edge-wait state are internal. These connections remain for future top-level integration. Person A owns this integration.

### 6.2 Sequencer ↔ mailboxes (proposed stable contract)

```systemverilog
// To/from Person B's data_mailboxes
logic [7:0] host_in_data, host_out_data;
logic       host_in_valid, host_in_ready;
logic       host_out_valid, host_out_ready;

logic [7:0] core_pull_data, core_push_data;
logic       core_pull_valid, core_pull_ready;
logic       core_push_valid, core_push_ready;
```

Person B's standalone module is the **only** owner of both mailbox data registers and valid bits. A's controller and register-file write arbitration are the **only** sources of core `core_pull_ready` and `core_push_valid`. Wire these signals once in top-level integration; no duplicate request FSM is required in the mailbox module.

**Avoid a combinational loop:** B's `core_pull_valid` and `core_push_ready` depend on registered mailbox occupancy, not on `core_pull_ready` or `core_push_valid`. The controller's retirement decision can depend combinationally on these registered-status outputs.

### 6.3 RTL file ownership suggestion

```text
rtl/
  pc.sv                     # Existing PC (A owns required integration)
  control_unit.sv           # A: decode, pc_sel, loop/pin control, DATA_IO gating
  loop_unit.sv              # Optional A-only extraction for 6 loop state bits
  shift_datapath.sv          # Existing B-owned GPIO sync and sole RF writeback owner
  data_mailboxes.sv         # B: two independent 1-entry mailboxes
  host_uart_rx.sv           # B: optional later milestone
  host_uart_tx.sv           # B: optional later milestone
  <existing_core_top>.sv    # Integration change only after A/B interface freeze

tb/
  tb_loop_pin_ctrl.sv       # A standalone branch/loop/edge-wait tests
  tb_data_mailboxes.sv      # B standalone ready/valid tests
  tb_host_uart.sv           # B optional UART test
  tb_control_io_integration.sv # Shared integration test
  programs/                # Shared program bytes (agreed test images)

docs/
  README_LOOP_PIN_CTRL_DATA_IO_microarchitecture.md
```

`<...>` indicates a **placeholder for the repository's actual filename**, not a file to create literally. Keep the existing `rtl/` and `tb/` conventions and existing `isa_pkg.sv` field definitions; avoid duplicating opcode bit positions as conflicting local constants.

### 6.4 Person-by-person pre-merge deliverables

**Person A:** loop count/target resolution, taken-branch loop invalidation, level/edge wait semantics, pin-select/flag decode, PC source mux, all CTRL-specific unit tests; provide stubbed `core_pull_valid`, `core_pull_data`, `core_push_ready` to prove blocking/retiring DATA_IO sequencing *without B's RTL*.

**Person B:** single-entry host-to-core and core-to-host mailboxes, well-defined handshake/status outputs, standalone drive/read testbenches; optionally complete host UART RX/TX and tests after the mailbox tests pass. B tests by mimicking the controller with `core_pull_ready`, `core_push_valid`, `core_push_data` and does not require A's controller to compile.

**Joint:** integrate top-level ports and shared RF writeback, run a program that pulls a byte, transmits or loops, then pushes a captured byte; confirm waveforms before merging. Both must approve any changed port names/widths or unplanned register ownership.

### 6.5 Merge plan

1. Agree on the proposed port list and `pc_sel`/retirement semantics in a small shared commit.
2. Branch A: `feat/loop-pin-control`; branch B: `feat/data-mailboxes`.
3. Independently compile unit TBs and run directed tests; neither branch modifies the other's RTL files.
4. Review and merge A and B, then make one **joint integration PR** for shared controller/top-level wiring (or A owns controller changes reviewed by B).
5. Capture waveforms for `PC`, `IR`, `IMM`, FSM state, PC completion selection (a future `retire` signal if added), `loop_active`, `loop_remaining`, synchronized pins, `edge_armed`, `cmp_flag`, mailbox valid/data, and core/host handshakes.
6. Only after the core passes, add physical host UART and program-loader work; check I/O pin budget and synthesis area.

---

## 7. End-to-end acceptance tests

| ID | Program/stimulus | Pass criteria |
|---|---|---|
| L1 | Body + `LOOP 3,target` | Exactly 3 total body executions; PC falls through after last loop |
| L2 | Encoded `LOOP 0,target` | Exactly 32 total body executions; counter never underflows |
| L3 | Taken vs untaken `BRANCH_PIN` in a loop | Only taken branch aborts active loop; target selection correct |
| P1 | Wait for P0 high/low | Immediate/delayed completion; PC held while blocking |
| P2 | Rising/falling transition before vs after arm | Pre-arm edge does not satisfy the wait; post-arm edge does |
| P3 | `BR_TRUE`/`BR_FALSE`, `JMP` | Correct flag semantics, legal/reserved decode and 3-cycle path |
| D1 | Empty mailbox → host writes 0xA5 → `PULL R0` | Core stalls first; R0=0xA5 and input entry consumed exactly once |
| D2 | `PUSH R0` while output full → host reads | Core waits, then pushes once and retires; no byte duplicates |
| D3 | Host sends 0x41 → PULL → programmable UART TX | Protocol pin emits correct UART frame after firmware timing calibration |
| D4 | Programmable UART RX → SHIFT_IN → PUSH → host UART TX | Host receives the byte; ASCII visible in PuTTY and raw bytes checked in Python |
| X1 | Reset during active loop / pin wait / DATA_IO stall | PC=0, loop inactive, edge wait disarmed, mailboxes empty, no stray transfer |

Check **cycle counts at instruction retirement edges**, not just functional output values. A two-byte `LOOP` or conditional branch costs 3 clocks, and a nonblocking `DATA_IO` costs 2. Any extra blocked `EXECUTE` cycles are intentional and can affect UART/SPI/I2C bit timing. The ISA promises neither full-duplex hardware UART nor lossless frames if firmware blocks on `DATA_IO` during back-to-back traffic.

## 8. Decisions to freeze before implementation

- [ ] Existing PC is the sole PC owner; updates occur only on retirement.
- [ ] `LOOP` count is **total body passes** with encoded zero meaning 32; only one live loop.
- [ ] Taken non-LOOP branches clear `loop_active` and `loop_remaining`.
- [ ] `PIN_CTRL` mode determines 1-byte versus 2-byte length; reserved `BR_TRUE/BR_FALSE` encoding is rejected.
- [ ] Edge wait arms inside EXECUTE; no pre-arm edge detection.
- [ ] One shared two-flop input synchronizer per physical pin, not one per instruction.
- [ ] Mailboxes are **single entry** for the first integrated RTL milestone, with ready/valid semantics.
- [ ] `PULL` and `PUSH` block, preserve PC/IR while blocked, and transfer exactly once upon handshake.
- [ ] DATA_IO reads/writes the existing R0/R1; Person B does not create a second register file.
- [ ] Host UART is a dedicated PC link and separate from programmable P0..P3; its RX overflow/flow-control policy is documented before hardware demo.
- [ ] Person A owns all control-flow/controller edits; Person B owns mailbox/UART modules. Shared top-level integration is a jointly reviewed change.
- [ ] Program loading for a real ASIC is a separate future design task, not solved by `$readmemh`.

**Suggested first complete milestone:** prove `LOOP`, every legal `PIN_CTRL` submode, and blocking `PULL`/`PUSH` with a **testbench host**. Treat PuTTY-hosted UART as the next demo feature, not an architectural dependency.
