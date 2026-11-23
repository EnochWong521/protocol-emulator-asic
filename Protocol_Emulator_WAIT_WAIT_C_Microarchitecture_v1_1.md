# WAIT / WAIT_C microarchitecture: elapsed-cycle compensation

This contract supersedes the former execution-only WAIT duration and experimental
background START/DONE design. Instruction encodings return to the original ISA.
The elapsed-WAIT and UART TX/RX suites have been simulated with Icarus.

## Encodings and interface

| Instruction | Byte | Meaning |
|---|---|---|
| WAIT_C T | two bytes, opcode 000 | Configure T=1..8191; zero stalls without writes |
| WAIT FULL | 20 | Completion-to-completion interval T |
| WAIT HALF | 28 | Interval max(1,T >> 1) |
| WAIT QUARTER | 30 | Interval max(1,T >> 2) |
| SET_DIR RIGHT/LEFT | 38/39 | Direction only; no timing reference reset |

Bytes 21/22 are reserved again. There is no background timer or START/DONE.
The core external interface adds `timing_overrun`, a sticky status output.
The controller retains wait_start/wait_tick and timer status, and adds wait_rebase
to the timer. It pulses on completed WAIT_PIN instructions.
`wait_is_single_cycle` now means that this WAIT can complete on its first execution
edge because its interval is already due; it no longer means D=1.

## State and clock-edge contract

The timer owns T, `elapsed_cycles`, `epoch_valid`, `wait_remaining`, and
`timing_overrun`. All reset synchronously high: T=4, counters=0, epoch invalid,
overrun=0. The controller keeps FETCH, FETCH_OPERAND, EXECUTE, WAIT_REMAIN.

1. Before the first completed timer WAIT, elapsed stays zero. That first WAIT takes
   D execution edges plus its fetch, establishing a reference at completion.
2. After any timer WAIT completes, elapsed is zero. Each subsequent clock increments
   it, including fetches, LOOP, GPIO waits, SET_DIR, and WAIT_C. Saturate at 8191.
3. At a WAIT's first EXECUTE edge, include that edge: projected elapsed = elapsed+1
   using 14 bits. If projected elapsed >= D, complete immediately. Otherwise load
   wait_remaining = D - projected elapsed and enter WAIT_REMAIN.
4. In WAIT_REMAIN, decrement once per tick. When pre-edge remaining=1, complete
   on that edge. Completion resets elapsed=0 and establishes the next reference.
5. At first EXECUTE, projected elapsed > D with a valid reference raises sticky
   timing_overrun. Equality is on-time. A late WAIT still completes and restarts the
   reference; it does not halt, wrap, or repeatedly catch up. Reset clears the flag.
6. WAIT_C changes T without resetting elapsed. Invalid zero writes stall as before.
   WAIT_PIN completion sets elapsed=0 and marks the reference valid, aligning
   subsequent waits to the observed external event. Branches and SET_DIR do not
   change it. Rebase does not clear sticky overrun.

The first WAIT's countdown uses the same load/tick contract, while elapsed remains
zero until the reference is established. No additional counter runs independently.

## Firmware placement and examples

Place WAIT immediately before each SHIFT_OUT. Both output instructions take two
clocks after WAIT completion; their equal offsets cancel when measuring pin edges.
Moving LOOP between a WAIT and its output would break that relationship.

`examples/pin_pulse.hex` uses T=8 and FULL before both outputs: expected high and
low intervals are eight clocks. The low path consumes output(2)+LOOP(3)+WAIT fetch
and execution(2), so seven clocks is its minimum achievable interval.

`examples/pin_pulse_half.hex` uses T=16, HALF before HIGH and FULL before LOW:
expected high=16 clocks, low=8 clocks. T is cycles per bit, not a baud-rate number.
A T=8 HALF would request four clocks and overrun this loop path.

## Verification

- tb_wait_timer: initial reference, FULL/HALF/QUARTER compensation, exact deadlines,
  reconfiguration, sticky overrun, T=1/2/8191, saturation and reset.
- tb_control_unit: full-width WAIT_C and zero rejection, SET_DIR, compensated waits,
  missed intervals and reset with the connected core.
- tb_protocol_core: ten FULL/FULL pulses or FULL/HALF pulses, exact expected edges,
  enables, LOOP, final self-jump, no-overrun and reset.
- Existing decode, PC, GPIO startup and datapath suites remain available.

See README.md for compile/run commands. All eleven Icarus suites pass. UART TX
was additionally checked for all 256 payloads; RX for all 256 nominal payloads
plus idle gaps, back-to-back frames, false start, bad stop, recovery, and roughly
+/-1% sender baud mismatch. These are RTL checks, not electrical/silicon validation.
