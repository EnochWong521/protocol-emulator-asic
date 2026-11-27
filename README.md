# Protocol Emulator ASIC

Small non-pipelined protocol emulator for programmable UART, SPI and I²C sequences.
[Competition background](https://blog.janestreet.com/protocol-emulator-asic-competition/).

The current RTL implements instruction fetching, PC selection, WAIT/WAIT_C, SET_DIR,
SHIFT decoding and datapath, MOVE decoding and writeback, and unsigned EQ/LT/GT
comparison with a persistent flag. These have standalone/controller tests.
`rtl/protocol_core.sv` connects these modules, with a combinational external
instruction-memory interface and separate GPIO output value/enable signals.
An instruction-driven high/wait/low GPIO smoke test verifies the first complete path.
LOOP and all legal PIN_CTRL modes now have controller execution logic and PC target
loading; their functional verification is deferred. DATA_IO has length decoding only.
Firmware-driven UART 8N1 TX/RX, SPI controller and single-controller I²C demos
are simulated. PIN_MODE configures open-drain outputs for I²C. Synthesis area
and static timing results remain pending.

## Architecture references

- [ISA encodings](protocol_emulator_ISA_v1_proposed.md)
- [WAIT timing and current fetch/control interfaces](Protocol_Emulator_WAIT_WAIT_C_Microarchitecture_v1_1.md)
- [SHIFT/MOVE/CMP ownership and interfaces](Protocol_Emulator_Shift_Move_Compare_Microarchitecture_v1.md)
- [Future LOOP/PIN_CTRL/DATA_IO design](README_LOOP_PIN_CTRL_DATA_IO_microarchitecture.md)

Microarchitecture documents define the agreed implementation contracts. RTL and tests
share constants from `rtl/isa_pkg.sv`; compile it before importing modules.

| Module | Owned state |
|---|---|
| `pc` | PC |
| `inst_fetch` | IR, IMM and combinational instruction addressing |
| `control_unit` | Four-state FSM, persistent `direction`, loop counter/active state, pin-edge wait state |
| `wait_timer` | T, elapsed counter, pending WAIT count, timing_overrun |
| `register_file`, instantiated by `shift_datapath` | R0/R1, one write port |
| `shift_datapath` | GPIO input synchronization/validity, logical output value/drive request, open-drain mask and physical output value/enable |
| `cmp_datapath` | `cmp_flag` |

The core connects `inst_fetch.imm` directly to the data/comparison consumers and
`pc.pc_target`, the shared GPIO synchronizer and validity to the controller, and
`cmp_datapath.cmp_flag` back to the controller. `PC_TARGET` (`11`) loads the
absolute byte target on a taken branch or repeating LOOP. The register bank stays
inside `shift_datapath`; the comparator reads that same bank.
`gpio_sync_valid` resets low and rises with the second post-reset sample. SHIFT_IN
and pin-dependent waits/branches hold until it is high; edge waits arm only on a
valid sample. An initial SHIFT_IN or level WAIT_PIN can therefore take an extra
startup clock. JMP, flag branches, and timer WAIT do not depend on pin validity.
All resets are synchronous and active-high. Current reserved/unsupported instructions
stall in EXECUTE without writes; no `illegal_inst` or `retire` output exists.

## Compensated WAIT changes

The original WAIT encodings are retained: FULL=20, HALF=28, QUARTER=30.
Experimental START/DONE instructions, background counter, examples and tests are
removed; 21/22 are reserved again. This changes WAIT semantics: it now includes
all clocks elapsed since the previous timer WAIT completed, rather than adding a
fresh D execution-clock delay. Existing firmware timing expectations must change.

The first WAIT after reset establishes the reference and uses D execution clocks.
Later WAITs subtract intervening fetch/execution clocks from the requested interval.
WAIT_C changes T without resetting the reference. Each completed timer WAIT resets
elapsed. WAIT_PIN completion reanchors the reference to the observed external event. A
saturating counter prevents wraparound.

If instructions already exceeded the requested interval, WAIT finishes immediately
and sets `protocol_core.timing_overrun` until reset. The completion becomes the new
reference. This reports the missed timing; it cannot make instructions run faster.

| Changed area | What changed |
|---|---|
| Timer | Elapsed counter, first-reference handling, remainder calculation, sticky overrun |
| ISA/controller/core | Original legal encodings restored; timer status keeps the four-state FSM; core exposes timing_overrun |
| Firmware | WAIT immediately before each output, so equal post-WAIT output delays cancel |
| Tests/docs | Updated unit/integration timing expectations; background experiment removed |

## Ten pulses: eight clocks high and low

`examples/pin_pulse.hex` contains this manually encoded program (no assembler needed):

```text
WAIT_C 8
pulse:
    WAIT FULL
    SHIFT_OUT R0, P0, HIGH
    WAIT FULL
    SHIFT_OUT R0, P0, LOW
    LOOP 10, pulse
done:
    JMP done
```

The low path's LOOP executes before the next WAIT and is included in that interval.
Expected high=8 clocks, low=8 clocks. With the testbench's 10 ns clock, each is 80 ns.
First HIGH is expected at 155 ns and first LOW at 235 ns. These values have been checked by simulation.

From the repository root, compile and run:

```bash
mkdir -p build
iverilog -g2012 -s tb_protocol_core -o build/tb_protocol_core.vvp \
  rtl/isa_pkg.sv rtl/pc.sv rtl/inst_fetch.sv rtl/control_unit.sv \
  rtl/register_file.sv rtl/shift_datapath.sv rtl/cmp_datapath.sv \
  rtl/wait_timer.sv rtl/protocol_core.sv tb/tb_protocol_core.sv
(cd build && vvp tb_protocol_core.vvp +program=../examples/pin_pulse.hex +vcd)
```

Open `build/protocol_core.vcd` in WaveTrace and add clk, reset, gpio_out_value,
gpio_out_enable, timing_overrun, and dut.u_timer.elapsed_cycles under tb_protocol_core.
Zoom to fit. Old generated VCDs are stale until you run the new simulation.

## Full-bit high, half-bit low

`examples/pin_pulse_half.hex` uses T=16, WAIT HALF before HIGH and WAIT FULL before
LOW. Expected high=16 clocks (160 ns) and low=8 clocks (80 ns). Run the same binary:

```bash
(cd build && vvp tb_protocol_core.vvp +half_low \
  +program=../examples/pin_pulse_half.hex +vcd)
```

This overwrites protocol_core.vcd. Reload it in WaveTrace. T=16 is chosen because
this loop cannot fit its minimum seven-clock low path into a four-clock interval.

## UART transmit: complete 8N1 frame

`examples/uart_tx_8n1.asm` is the readable assembly reference and
`examples/uart_tx_8n1.hex` is its manually encoded image. No assembler is required.
This example transmits 0x55 on P0, least-significant bit first, without parity,
with one start bit and one stop bit. It holds idle high before and after the frame.
It loads R0 with MOV rather than the still-unimplemented DATA_IO/PULL instruction.
This is TX only; it does not implement receive or host transport.

T=868 clocks at the testbench's 100 MHz clock gives an 8.68 microsecond bit period
(approximately 115200 baud). WAIT immediately precedes every output, and the data
loop's three clocks are included in the next bit period. The final HIGH confirms
that the full stop interval has passed before the program enters its self-jump.

Compile and simulate from the repository root:

```bash
mkdir -p build
iverilog -g2012 -s tb_uart_tx -o build/tb_uart_tx.vvp \
  rtl/isa_pkg.sv rtl/pc.sv rtl/inst_fetch.sv rtl/control_unit.sv \
  rtl/register_file.sv rtl/shift_datapath.sv rtl/cmp_datapath.sv \
  rtl/wait_timer.sv rtl/protocol_core.sv tb/tb_uart_tx.sv
(cd build && vvp tb_uart_tx.vvp +uart_program=../examples/uart_tx_8n1.hex +vcd)
```

Open `build/uart_tx.vcd` in WaveTrace. Under `tb_uart_tx`, add `tx`, `clk`, and
`timing_overrun`. `tx` models an external idle-high pull-up while GPIO is released.
For internal detail, add `dut.r0_data` and `dut.u_timer.elapsed_cycles`.

Expected sequence: idle HIGH, start LOW, data **1 0 1 0 1 0 1 0**, stop HIGH,
then idle HIGH. Each frame bit occupies 868 clocks / 8.68 microseconds.
The expected start is 17.485 microseconds and stop begins at 95.605 microseconds;
its full interval ends at 104.285 microseconds. Simulation checks confirm these times. The testbench checks every output clock,
exact shift commit edges, eight data bits, stop length, enables and no overrun.

## UART receive: external 8N1 frames

`examples/uart_rx_8n1.asm` and its hex image receive on P1 with T=868. Firmware
validates the start bit near its center, shifts eight LSB-first bits into R1,
checks the stop bit, and copies a valid byte into R0. P2 records that a valid frame
was received; P3 records a bad stop bit. Both markers remain high until reset.
Host PUSH/mailbox transport is still unimplemented.

RX testing exposed a timing-reference bug after arbitrary idle gaps. The fix is
that **every completed WAIT_PIN reanchors elapsed timing to that completion edge**.
This aligns WAIT HALF to the newly observed start event, rather than a previous
frame's timer WAIT. Existing timer waits and TX keep their timing behavior.
The synchronized start detection introduces a few clock cycles of sampling offset;
data samples remain one local bit period apart and near the bit centers.

Compile and run:

```bash
iverilog -g2012 -s tb_uart_rx -o build/tb_uart_rx.vvp \
  rtl/isa_pkg.sv rtl/pc.sv rtl/inst_fetch.sv rtl/control_unit.sv \
  rtl/register_file.sv rtl/shift_datapath.sv rtl/cmp_datapath.sv \
  rtl/wait_timer.sv rtl/protocol_core.sv tb/tb_uart_rx.sv
(cd build && vvp tb_uart_rx.vvp +rx_program=../examples/uart_rx_8n1.hex +vcd)
```

Open `build/uart_rx.vcd` in WaveTrace. Add `rx`, `dut.r1_data`, `dut.r0_data`,
`dut.exec_shift_in`, `value` (P2/P3 markers) and `overrun` under `tb_uart_rx`.
The default run checks seven good frames, one framing error, a false start,
arbitrary idle gaps, back-to-back frames, approximately +/-1% sender baud mismatch,
and recovery without reset. Input edges exercise eight asynchronous phases; each
data sample is asserted to be within one eighth of a bit period of its expected
center. Bad frames must preserve the previous valid byte. Add `+exhaustive` to
also receive all 256 byte values.
TX was separately checked for all 256 payloads using `+payload=XX`.

These are digital RTL checks at 100 MHz and nominal 115200 baud, not physical
silicon timing, electrical validation, formal proof, or a general UART peripheral
with host buffering. Simultaneous TX/RX on one sequential core is not demonstrated.

## SPI controller: full-duplex byte transfers

`examples/spi_mode0.asm` documents the manually encoded `spi_mode0.hex` image.
It sends 0xA5 MSB first in mode 0, using P0=SCLK, P1=MOSI, P2=MISO and
P3=active-low CS. R0 supplies TX and R1 receives a byte. Existing instructions
implement the complete transfer; no RTL or ISA extension is required.

Both phase waits use WAIT FULL with T=64 **clocks per half-period**. At the
PYNQ-Z2's 125 MHz clock, SCLK has 512 ns high/low phases, a 1024 ns period,
and a 976.5625 kHz frequency. The target changes MISO on the setup edge;
firmware reads the synchronized input after the sampling edge. The target's
data-valid delay and the two-stage synchronizer must fit the selected timing.

From the repository root, run the SPI test:

```bash
bash scripts/run_spi_sim.sh
```

The test checks the example ROM first, then all four SPI modes, both bit orders,
every TX byte and every RX byte (RX=TX xor 0x96), 1/5/21 ns target response delays,
and T=64/16 half-periods (976.5625 kHz / 3.90625 MHz). Its independent target
checks MOSI, eight sampling edges, sixteen SCLK transitions, exact half-periods,
8 ns MOSI setup/hold requirements, CS framing and MISO pin ownership. The core's
RX result, shift count, exhausted TX register, reset recovery and absence of
timing_overrun are checked too. This covers single-byte controller transactions;
it does not establish a maximum SPI speed, peripheral mode, physical board timing,
or host PULL/PUSH support.

For a small waveform, run `bash scripts/run_spi_sim.sh +vcd`. It tests only the
example mode-0 image and writes `spi.vcd` in the printed artifact directory.
View `cs_n`, `sck`, `mosi`, `pins[2]`, `dut.r1_data` and `overrun` under `tb_spi`.
`bash scripts/run_spi_sim.sh +too_fast` deliberately exits with an expected
failure: T=8 cannot fit the firmware loop and must assert timing_overrun.

The FPGA wrapper currently defaults to a UART ROM. To run SPI on the board,
provide the SPI image as a Vivado memory initialization source and select it
with top-level `PROGRAM_FILE`; changing simulation firmware does not change
the already programmed bitstream. The SPI pin mapping above uses all four
Pmod B GPIO signals in `fpga/constraints/pynq_z2.xdc`.

## I²C controller: write, repeated START and two-byte read

`PIN_MODE mask8` is now implemented as `56 mask8`. Operand bits [3:0] select
open-drain mode per pin; [7:4] must be zero. `56 03` makes P0/P1 open-drain.
Logical LOW drives the pad; logical HIGH or RELEASE releases it. Physical
open-drain output data stays LOW, and a registered enable controls drive/release.
Reset restores push-pull modes and releases all pins. Existing UART/SPI firmware
retains its previous behavior unless it explicitly executes PIN_MODE.

`examples/i2c_write_read.asm` documents the complete 135-byte program in
`i2c_write_read.hex` (padded to 256 bytes). With P0=SCL and P1=SDA it writes 0x10
to seven-bit target address 0x50, issues a repeated START, reads two bytes, ACKs
the first, NACKs the second and sends STOP. R0/R1 hold the received bytes.
P2 marks success; P3 marks a target NACK. NACK handling sends STOP after finishing
the required HIGH phase. There is no host mailbox transfer in this example.

From the repository root:

```bash
bash scripts/run_i2c_sim.sh
bash scripts/run_i2c_sim.sh +vcd
```

The runner first checks all 16 PIN_MODE masks, 256 shifted-byte combinations,
fixed outputs/release, all 240 invalid mask operands, reserved 5E, state retention,
loop preservation, mode replacement, external LOW readback and reset priority.
The bus test uses an independent edge-driven target and wired pull-ups. It checks
312 transactions: all 256 write values and both received byte values; normal and
repeated START; target ACK and NACK at either address/data phase; controller ACK
and final NACK; STOP; clock stretching; and reset/restart during stretching.
It also checks that the controller never drives SCL/SDA HIGH, including between
CPU edges, and never misses a WAIT deadline.

At the 125 MHz FPGA clock, the example uses T=625, producing minimum SCL HIGH/LOW
phases of 5040/5000 ns (about 99.6 kHz during uninterrupted byte clocks). Fast-mode
checks use T=163, producing at least 1344/1304 ns (about 377.6 kHz without extra
loading). These intentionally stay below the 100/400 kHz limits. The tests assert
mode-specific clock periods, HIGH/LOW widths, SDA setup and START/STOP timing,
and include 80 ns rising-threshold delays, 17 ns target response delays and
asynchronous stretches. Threshold delays approximate digital behavior; they do
not establish analog rise time, electrical compliance or physical board timing.

`+vcd` runs only the example transaction after PIN_MODE checks and writes `i2c.vcd`
in the printed artifact directory. View `scl`, `sda`, `target_scl_low`, `value`,
`enable`, `dut.r0_data`, `dut.r1_data` and `overrun` under `tb_i2c`.

For FPGA use, connect Pmod B pin 1 (P0/SCL) and pin 2 (P1/SDA), plus ground.
Provide appropriately sized physical pull-ups to 3.3 V (or verify existing module
pull-ups). Copy the hex image to `i2c_write_read.mem`, add it as a Vivado memory
initialization source, and set top-level `PROGRAM_FILE` to that filename before
rebuilding the bitstream. PROGRAM_FILE still defaults to the existing UART ROM.
The core/ISA does not enable FPGA pull-ups.

This milestone supports a single I²C controller with seven-bit addressing.
It does not implement target mode, multi-controller arbitration, a pin-wait
timeout, or a general-purpose host-driven I²C API. A permanently held LOW line
still blocks WAIT_PIN until reset or external release.

## Run all fourteen suites

All suites pass in Icarus. In Bash from the repo root:

```bash
set -e
sources=(rtl/isa_pkg.sv rtl/pc.sv rtl/inst_fetch.sv rtl/control_unit.sv
         rtl/register_file.sv rtl/shift_datapath.sv rtl/cmp_datapath.sv
         rtl/wait_timer.sv rtl/protocol_core.sv)
tops=(tb_pc tb_wait_timer tb_control_unit_fetch tb_control_unit tb_cmp_datapath
      tb_register_file tb_shift_datapath tb_gpio_sync_startup tb_protocol_core tb_uart_tx tb_uart_rx tb_spi tb_pin_mode tb_i2c)
repo_dir=$PWD
build_dir=$(mktemp -d /tmp/protocol-emulator-XXXXXX)
for top in "${tops[@]}"; do
  iverilog -g2012 -s "$top" -o "$build_dir/$top.vvp" "${sources[@]}" "tb/$top.sv"
  (cd "$build_dir" && vvp "$build_dir/$top.vvp" +program="$repo_dir/examples/pin_pulse.hex" \
    +uart_program="$repo_dir/examples/uart_tx_8n1.hex" \
    +rx_program="$repo_dir/examples/uart_rx_8n1.hex" \
    +spi_program="$repo_dir/examples/spi_mode0.hex" \
    +i2c_program="$repo_dir/examples/i2c_write_read.hex")
done
```
