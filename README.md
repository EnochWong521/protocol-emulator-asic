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
No UART/SPI/I²C demo, synthesis area or static timing result is claimed.

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
| `wait_timer` | T and remaining wait counter |
| `register_file`, instantiated by `shift_datapath` | R0/R1, one write port |
| `shift_datapath` | GPIO input synchronization/validity and output value/enable |
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

## Pin pulse example

[`examples/pin_pulse.hex`](examples/pin_pulse.hex) is a manually encoded program
loaded with `$readmemh` by `tb_protocol_core`:

```text
0x00: WAIT_C 8
0x02: SHIFT_OUT R0, P0, HIGH
0x03: WAIT FULL
0x04: SHIFT_OUT R0, P0, LOW
0x05: JMP 0x05
```

Fixed HIGH/LOW output modes do not modify R0. The pin starts released, drives high
on active clock edge 5, and drives low on edge 16. The high pulse lasts **11 clocks**:
one WAIT fetch + eight WAIT execution clocks + two LOW instruction clocks. The final
self-jump keeps P0 driven low; the ISA has no HALT. Other pins stay released.

Provide instruction data as `inst = memory[inst_addr]` with no registered read
latency. GPIO pad buffers belong outside the core and drive only when the matching
`gpio_out_enable` bit is high. Reset is synchronous, active-high, and restarts at PC 0.

## Run all nine suites with Icarus

From the repository root, in Bash with `iverilog` and `vvp` installed:

```bash
set -e
sources=(rtl/isa_pkg.sv rtl/pc.sv rtl/inst_fetch.sv rtl/control_unit.sv
         rtl/register_file.sv rtl/shift_datapath.sv rtl/cmp_datapath.sv rtl/wait_timer.sv
         rtl/protocol_core.sv)
tops=(tb_pc tb_wait_timer tb_control_unit_fetch tb_control_unit
      tb_cmp_datapath tb_register_file tb_shift_datapath tb_gpio_sync_startup
      tb_protocol_core)
repo_dir=$PWD
build_dir=$(mktemp -d /tmp/protocol-emulator-XXXXXX)
for top in "${tops[@]}"; do
    iverilog -g2012 -s "$top" -o "$build_dir/$top.vvp" "${sources[@]}" "tb/$top.sv"
    (cd "$build_dir" && vvp "$build_dir/$top.vvp" +program="$repo_dir/examples/pin_pulse.hex")
done
printf 'Artifacts: %s\n' "$build_dir"
```

A Makefile is optional. The source lists and selected top module make the commands
independent of filename sorting. Timer/controller suites write VCDs in the artifact
directory; the new register, shift and comparator suites enable dumping with `+vcd`.
For example, after the commands above:

```bash
(cd "$build_dir" && vvp "$build_dir/tb_shift_datapath.vvp" +vcd)
gtkwave "$build_dir/shift_datapath.vcd"
```

To generate the pin pulse waveform after compiling the suites:

```bash
(cd "$build_dir" && vvp "$build_dir/tb_protocol_core.vvp" \
    +program="$repo_dir/examples/pin_pulse.hex" +vcd)
gtkwave "$build_dir/protocol_core.vcd"
```

Inspect `clk`, `reset`, `inst_addr`, `gpio_out_value[0]`, and `gpio_out_enable[0]`.

## Run the same suites with Verilator

Reuse the `sources`, `tops` and `build_dir` variables above. Requires Verilator and a C++ toolchain:

```bash
for top in "${tops[@]}"; do
    verilator --binary --timing --trace -Wno-fatal --top-module "$top" \
        --Mdir "$build_dir/obj-$top" "${sources[@]}" "tb/$top.sv"
    (cd "$build_dir" && "$build_dir/obj-$top/V$top" +program="$repo_dir/examples/pin_pulse.hex")
done
```

`--trace` supports the optional `+vcd` argument. Existing warnings include RTL/testbench
timescale differences and integer-to-counter-width conversions in the timer testbench.
They do not replace checking that compilation and every suite finish successfully.

## Verification coverage

The suites include a focused GPIO startup regression. Complete LOOP/PIN_CTRL
functional coverage remains deferred; the core smoke test also exercises JMP self.

| Suite | Checks |
|---|---|
| `tb_pc` | 518 selector/address/reset checks |
| `tb_wait_timer` | 25 timer tests |
| `tb_control_unit_fetch` | All 256 lengths, 32 MOVE-family encodings, 560 cycle checks |
| `tb_control_unit` | 24 WAIT and 8 WAIT_C timing cases; original 25-cycle and 765-cycle reference programs |
| `tb_cmp_datapath` | 432 comparisons, 20 retention/invalid-command cases, 459 cycle checks |
| `tb_register_file` | 29 reset/write/retention checks |
| `tb_shift_datapath` | MOVE, 16 SHIFT_IN bytes, 16 SHIFT_OUT bytes, 48 fixed-output cases; 680 cycle checks |
| `tb_gpio_sync_startup` | 24 startup cases: every pin/wait mode, initial SHIFT_IN into either register, reset clears validity/arming |
| `tb_protocol_core` | Checked-in GPIO pulse program: exact HIGH/LOW edges and output enables, 11-clock pulse, JMP self, reset after execution |

The datapath suite checks both registers, directions and every pin, synchronization
latency, output of the old register endpoint, untouched-pin retention and synchronous
reset priority. Further core integration tests must verify MOV followed by CMP, SET_DIR followed
by actual shifts, GPIO commit edges and flag retention across intervening instructions.
