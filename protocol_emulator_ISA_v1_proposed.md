# Protocol Emulator ISA — Proposed v1.0 Freeze

Status: **UART-capable implementation proposal** (not yet verified in RTL). This is a *revised design* based on the team's `ISA.md`, not a transcription of that draft.

## Design contract

- 8 primary opcodes, 3 bits each, in instruction bits `[7:5]`.
- Byte-addressed program memory, initially 256 x 8; PC is 8 bits, reset PC = `0x00`.
- Instructions occupy 1 or 2 bytes. First byte always has the opcode; the opcode and submode determine the length. A 2-byte instruction has its payload at `PC+1`.
- One sequential, non-pipelined engine. Two 8-bit data registers, `R0` and `R1`.
- Four protocol pins `P0..P3`, selected by 2 bits; each has output-value, output-enable, and synchronized input. Input can be read as 0 or 1; Z is **output release**, not an input condition.
- Single 13-bit time-base register `T`, one timing countdown, one 5-bit hardware loop counter and `loop_active`, one equality flag, one shift direction flag.
- No general data RAM or ALU in v1. One host-to-engine mailbox and one engine-to-host mailbox (each 8 bits plus valid/ready semantics).
- `PULL` and `PUSH` are architectural operations; the physical host and program-loading interface is **separate** and must be designed before tapeout. During initial RTL testing the testbench can supply that interface.
- Only one active loop, no nested loops; no guaranteed simultaneous UART TX/RX. Protocol timing is bounded by the engine's instruction latency.

## Opcode table

| `[7:5]` | Name | Bytes | Semantics |
|---|---|---|---|
| `000` | `WAIT_C` | 2 | Configure 13-bit base period `T` |
| `001` | `WAIT` / `SET_DIR` | 1 | Wait full/half/quarter `T`, or configure shift direction |
| `010` | `PIN_CTRL` | 1 or 2 | Wait for level/edge, conditional branch, or unconditional jump |
| `011` | `LOOP` | 2 | Bottom-of-loop repetition |
| `100` | `SHIFT_IN` | 1 | Sample one pin bit and shift it into a register |
| `101` | `SHIFT_OUT` | 1 | Drive low/high/release or shift out one bit |
| `110` | `MOVE` | 1 or 2 | Immediate load/compare or register-to-register move/compare |
| `111` | `DATA_IO` | 1 | Blocking host `PULL` or `PUSH` |

## Bit-accurate encodings

### `000 WAIT_C T` (2 bytes)
- Byte 0: `[7:5]=000`, `[4:0]=T[12:8]`.
- Byte 1: `T[7:0]`.
- `T = {byte0[4:0], byte1[7:0]}` (unsigned 13-bit).
- Valid `T` is 1..8191; assembler rejects zero. Reset `T=4` but firmware should initialize it explicitly before use.
- Stores a **generic clock-cycle period**, not a UART-specific baud rate.

### `001 WAIT duration` / `SET_DIR` (1 byte)
- Byte 0: `[7:5]=001`, `[4:3]=submode`, `[2:0]=arg`.
- `submode=00`, `arg=000`: `WAIT FULL` — `D=T`.
- `submode=01`, `arg=000`: `WAIT HALF` — `D=max(1, T >> 1)`.
- `submode=10`, `arg=000`: `WAIT QUARTER` — `D=max(1, T >> 2)`.
- `submode=11`, `[2:1]=00`, `[0]=0/1`: `SET_DIR RIGHT/LEFT`.
- Other encodings reserved.
- `WAIT` spends exactly `D` clocks in its EXECUTE phase; fetch time and any intervening instructions are **additional** and must be included when deriving protocol timing.
- One global shift direction applies to both `SHIFT_IN` and `SHIFT_OUT`; reset is RIGHT.

### `010 PIN_CTRL` (1-byte wait, 2-byte branch)
- Byte 0: `[7:5]=010`, `[4:3]=pin`, `[2:1]=condition`, `[0]=mode`.
- `mode=1`: 1-byte WAIT operation; no second byte:
  - `condition=00`: `WAIT_PIN pin, LOW` (level).
  - `condition=01`: `WAIT_PIN pin, HIGH` (level).
  - `condition=10`: `WAIT_PIN pin, RISING` (edge).
  - `condition=11`: `WAIT_PIN pin, FALLING` (edge).
- `mode=0`: 2-byte branch; Byte 1 is **absolute byte address** (0..255):
  - `condition=00`: `BRANCH_PIN pin, LOW, target`.
  - `condition=01`: `BRANCH_PIN pin, HIGH, target`.
  - `condition=10`: `JMP target`; pin field ignored.
  - `condition=11`: `[4]=0` reserved; `[3]=0` means `BR_EQ target`; `[3]=1` means `BR_NE target`. (This reuses the low pin-select bit to invert the equality flag.)
- `BR_EQ` / `BR_NE` inspect the persistent equality flag last written by a `CMP` instruction; they do not read the GPIO input.
- Level waits complete once the sampled synchronized input has the requested logic level. Edge waits detect an input transition **while the instruction is armed in EXECUTE**. An edge that occurred before arming is not guaranteed to be caught.
- Normal pin reads report 0/1, never high impedance.
- Any **taken** non-LOOP branch clears the active loop state. This prohibits conditional flow inside a live loop in v1 (except fall-through conditions).

### `011 LOOP count, target` (2 bytes)
- Byte 0: `[7:5]=011`, `[4:0]=count`.
- Byte 1: 8-bit **absolute byte address** of the first instruction in the loop body.
- `count=1..31` repeats the body exactly that many times. `count=0` means 32 iterations.
- The loop body is executed **once before** the `LOOP` instruction is encountered.
- First encounter with `loop_active=0`: if `N=1`, fall through; otherwise set `remaining=N-1`, set `loop_active=1`, and jump to target.
- Subsequent encounters with `loop_active=1`: if `remaining>1`, decrement and jump to target; if `remaining=1`, set `remaining=0`, clear active, and fall through.
- One active loop only; nested loops and early exits are unsupported. A taken `PIN_CTRL` branch clears the active loop.
- The assembler must ensure a loop target is an opcode byte, never an extension byte.

### `100 SHIFT_IN reg, pin` (1 byte)
- Byte 0: `[7:5]=100`, `[4]=reg (0=R0,1=R1)`, `[3:2]=pin`, `[1:0]=00` (reserved otherwise).
- Samples the synchronized pin once when the instruction retires.
- If direction RIGHT: `Rn <- {sample, Rn[7:1]}`.
- If direction LEFT: `Rn <- {Rn[6:0], sample}`.
- A byte received LSB-first with RIGHT ends up in its conventional bit order after eight samples.

### `101 SHIFT_OUT reg, pin, mode` (1 byte)
- Byte 0: `[7:5]=101`, `[4]=reg (0=R0,1=R1)`, `[3:2]=pin`, `[1:0]=mode`.
- `mode=00`: drive pin 0 (`oe=1`, `out=0`), do not shift.
- `mode=01`: drive pin 1 (`oe=1`, `out=1`), do not shift.
- `mode=10`: release pin (`oe=0`, high-Z), do not shift.
- `mode=11`: drive register endpoint bit and shift selected register **once**:
  - RIGHT: `out <- Rn[0]`, `Rn <- {0, Rn[7:1]}`, `oe=1`.
  - LEFT: `out <- Rn[7]`, `Rn <- {Rn[6:0], 0}`, `oe=1`.
- Output updates at the retiring EXECUTE clock edge. Fixed modes ignore the register selection bit.
- I2C logical high is represented by RELEASE plus an **external pull-up**, not an actively driven 1.

### `110 MOVE` group (1 or 2 bytes)
- Byte 0: `[7:5]=110`, `[4]=destination/compare register`, `[3:2]=submode`, `[1:0]=00`.
- `submode=00`: `MOV_IMM Rn, imm8`; two bytes; write Rn from second byte.
- `submode=01`: `CMP_IMM Rn, imm8`; two bytes; set `eq_flag = (Rn == imm8)`.
- `submode=10`: `MOV_REG Rn, Rother`; one byte; copy the other 8-bit data register into Rn.
- `submode=11`: `CMP_REG Rn, Rother`; one byte; set `eq_flag = (Rn == Rother)`.
- MOV does not affect equality flag. CMP does not modify data registers. `eq_flag` resets to 0.
- A simple equality comparator is required, **not** a general arithmetic ALU.

### `111 DATA_IO` group (1 byte)
- Byte 0: `[7:5]=111`, `[4]=reg`, `[3]=mode`, `[2:0]=000`.
- `mode=0`: `PULL Rn`: when host-to-engine mailbox `valid=1`, consume byte and write Rn; otherwise stall at this instruction. Exactly one consumption occurs per instruction.
- `mode=1`: `PUSH Rn`: when engine-to-host mailbox has space, copy Rn and set `valid=1`; otherwise stall. Exactly one emission occurs per instruction.
- Initial hardware may use **single-entry 8-bit mailboxes with valid bits** rather than multi-entry FIFOs. The ISA deliberately does not expose FIFO depth.
- Host must service incoming/outgoing data in time; blocking `PUSH` can cause missed back-to-back protocol frames.

## PC and execution timing — UART v1 contract

- `FETCH_OPCODE`: read `mem[PC]`, latch opcode and first-byte fields (one system-clock cycle).
- If the opcode+submode requires a second byte: `FETCH_OPERAND`: read `mem[PC+1]`, latch extension (one cycle).
- `EXECUTE`: perform the instruction and update the PC (one cycle for ordinary instructions; WAIT/WAIT_PIN/DATA_IO can extend the EXECUTE state).
- Thus a nonblocking 1-byte instruction consumes **2 cycles** and a nonblocking 2-byte instruction **3 cycles**, including fetch.
- For `WAIT D`, EXECUTE lasts exactly D cycles (not D cycles plus one EXECUTE cycle). Fetch of WAIT still consumes one extra cycle. For waiting on a pin, EXECUTE lasts until the condition is satisfied, with at least one EXECUTE cycle.
- Ordinary register/flag/GPIO effects commit on the last EXECUTE clock edge. For branches/loops, PC updates on that edge.
- On ordinary fall-through, PC becomes `PC+instruction_length`; on taken branch/loop it becomes `target`. PC arithmetic is modulo 256. The assembler must reject any instruction that crosses the end of the 256-byte image or jumps into an immediate byte.
- `WAIT FULL` does **not** promise exactly T cycles between neighboring pin transitions or samples. The exact interval includes instructions before/after WAIT. The assembler/firmware author must account for instruction cycles or calibrate T using a waveform test.
- The initial engine has no independent hardware UART bit-clock. Supported baud/SPI/I2C rates are limited by the instruction-cycle overhead and synchronization latency.

## Reset

- Synchronous, active-high `rst` for first RTL implementation (reset style can be adapted at the Tiny Tapeout wrapper).
- `PC=0`, `R0=0`, `R1=0`, `T=4`, `shift_dir=RIGHT`, `eq_flag=0`, `loop_active=0`, `loop_remaining=0`.
- GPIO outputs default **high-Z** (`oe=0`). UART firmware must drive TX high before sending.
- Host mailboxes initially invalid/empty. Wait counter cleared; execution starts at PC0 after reset.
- Two-flop synchronizer per input pin; branch and shift operations read synchronized values only.

## Example pseudo-assembly — UART TX

```asm
    WAIT_C T_TX         ; T_TX calibrated for the instruction path
    SET_DIR RIGHT
    SHIFT_OUT R0, TX, HIGH  ; establish idle mark level

send_next:
    PULL R0            ; block until host supplies one byte
    SHIFT_OUT R0, TX, LOW  ; start bit
    WAIT FULL

send_bits:
    SHIFT_OUT R0, TX, SHIFT
    WAIT FULL
    LOOP 8, send_bits

    SHIFT_OUT R0, TX, HIGH ; stop bit
    WAIT FULL
    JMP send_next
```

Assembler syntax is consistent: `SHIFT_OUT register, pin, mode`, even when a fixed mode ignores the register bit. For the two-phase fetch implementation, loop-body timing includes a 3-cycle LOOP, so derive `T_TX` by measuring the generated waveform; do not simply use `round(Fclk/baud)` without subtracting instruction overhead.

## Example pseudo-assembly — UART RX

```asm
    WAIT_C T_RX
    SET_DIR RIGHT
rx_start:
    WAIT_PIN RX, FALLING
    WAIT HALF
    BRANCH_PIN RX, HIGH, rx_start  ; reject short low glitch
    WAIT FULL                      ; align approximately to D0 center
rx_bits:
    SHIFT_IN R1, RX
    WAIT FULL
    LOOP 8, rx_bits

    BRANCH_PIN RX, LOW, framing_error
    PUSH R1                        ; block until host can accept byte
    JMP rx_start
framing_error:
    WAIT_PIN RX, HIGH               ; wait for line to return idle
    JMP rx_start
```

The program relies on RX having adequate clocks/bit relative to instruction overhead. The exact WAIT_C timing for sampling must be derived from the specified execution cycles and checked in simulation. This program **does not promise** lossless back-to-back bytes if PUSH blocks or the next start edge occurs before WAIT_PIN is armed.

## Physical host interface (outside ISA)

The core ISA does not specify how external firmware and data arrive. The system must implement:
1. Program-image loading into 256x8 instruction memory while engine is halted/reset.
2. Host-to-engine mailbox data and valid/ready handshake.
3. Engine-to-host mailbox data and valid/ready handshake.
4. Separation of host-control pins from four programmable protocol GPIOs (or a documented pin-sharing scheme).

For early RTL simulation, memory may use `$readmemh` and the host mailbox may be driven from the testbench; a real reprogrammable taped-out ASIC still needs a physical loader/control interface.

## Explicit v1 limitations / future extensions

- Only four software-addressable protocol pins.
- One processor executes one instruction at a time; no simultaneous independent UART TX and RX engines.
- One active loop and no nested loops; taken conditional branches abort loop state.
- No arithmetic, masking, general-purpose data RAM, parity/CRC acceleration, interrupt system, or DMA.
- With only equality comparison, more sophisticated protocol-state logic may need added instructions later.
- Edge waits can miss events that happen before the instruction is armed; no edge FIFO in v1.
- Maximum WAIT_C period is 8191 clocks; longer waits can be synthesized in firmware, including LOOP, with instruction overhead.
- Higher-speed SPI and special I2C behavior may be limited by the number of instructions needed per bit.

## Minimal implementation acceptance tests

1. `WAIT_C 434` loads `T=434` from exactly two instruction bytes.
2. `MOV_IMM R0, 0xA5` consumes two bytes, writes R0, and advances PC by 2.
3. `SHIFT_OUT R0` right eight times emits `1,0,1,0,0,1,0,1`.
4. `SHIFT_IN R1` right while receiving those eight bits yields R1=`0xA5`.
5. `LOOP 8,target` executes the body exactly eight times, including the first pass.
6. `PIN_CTRL` correctly handles low/high, rising/falling, conditional branch, unconditional jump, EQ and NE conditions.
7. `PULL` and `PUSH` stall safely and each transfer exactly one byte on handshake.
8. Reset releases protocol outputs; I2C-style released output is never misinterpreted as readable Z.
9. UART TX meets chosen baud tolerance when cycles are measured **pin-edge to pin-edge**.
10. UART RX samples at centers and recovers from a false start and framing error for the chosen supported baud.

## Hardware bring-up order

1. PC + 256-byte test program + FETCH_OPCODE/FETCH_OPERAND/EXECUTE FSM; implement MOV_IMM and JMP first.
2. R0/R1 + SHIFT_OUT + GPIO value/output-enable; send a fixed UART start/data/stop pattern.
3. WAIT_C + WAIT + LOOP; transmit a whole byte using UART firmware.
4. PIN_CTRL + input synchronizers + SHIFT_IN; receive UART bytes.
5. CMP/BR_EQ/BR_NE, DATA_IO mailboxes and host testbench drivers.
6. Assemble complete UART programs, run waveform assertions and random test vectors, then synthesize early.
