# Protocol Emulator ASIC

Small non-pipelined protocol emulator for programmable UART, SPI and I²C sequences.
[Competition background](https://blog.janestreet.com/protocol-emulator-asic-competition/).

The current RTL implements instruction fetching, PC selection, WAIT/WAIT_C, SET_DIR,
SHIFT decoding and datapath, MOVE decoding and writeback, and unsigned EQ/LT/GT
comparison with a persistent flag. These have standalone/controller tests.
`protocol_core.sv` and complete instruction-driven datapath integration are pending.
LOOP and all legal PIN_CTRL modes now have controller execution logic and PC target
loading; their functional verification is deferred. DATA_IO has length decoding only.
No complete protocol demo, synthesis area or static timing result is claimed.

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

Immediate data goes directly from `inst_fetch.imm` to the data/comparison consumers.
For future integration, also connect `inst_fetch.imm` to `pc.pc_target`,
`shift_datapath.gpio_in_sync` to `control_unit.gpio_in_sync`, and
`shift_datapath.gpio_sync_valid` to `control_unit.gpio_sync_valid`, plus
`cmp_datapath.cmp_flag` to `control_unit.cmp_flag`. `PC_TARGET` (`11`) loads the
absolute byte target on a taken branch or repeating LOOP. No top-level is added.
`gpio_sync_valid` resets low and rises with the second post-reset sample. SHIFT_IN
and pin-dependent waits/branches hold until it is high; edge waits arm only on a
valid sample. An initial SHIFT_IN or level WAIT_PIN can therefore take an extra
startup clock. JMP, flag branches, and timer WAIT do not depend on pin validity.
All resets are synchronous and active-high. Current reserved/unsupported instructions
stall in EXECUTE without writes; no `illegal_inst` or `retire` output exists.

## Run all eight suites with Icarus

From the repository root, in Bash with `iverilog` and `vvp` installed:

```bash
set -e
sources=(rtl/isa_pkg.sv rtl/pc.sv rtl/inst_fetch.sv rtl/control_unit.sv
         rtl/register_file.sv rtl/shift_datapath.sv rtl/cmp_datapath.sv rtl/wait_timer.sv)
tops=(tb_pc tb_wait_timer tb_control_unit_fetch tb_control_unit
      tb_cmp_datapath tb_register_file tb_shift_datapath tb_gpio_sync_startup)
build_dir=$(mktemp -d /tmp/protocol-emulator-XXXXXX)
for top in "${tops[@]}"; do
    iverilog -g2012 -s "$top" -o "$build_dir/$top.vvp" "${sources[@]}" "tb/$top.sv"
    (cd "$build_dir" && vvp "$build_dir/$top.vvp")
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

## Run the same suites with Verilator

Reuse the `sources`, `tops` and `build_dir` variables above. Requires Verilator and a C++ toolchain:

```bash
for top in "${tops[@]}"; do
    verilator --binary --timing --trace -Wno-fatal --top-module "$top" \
        --Mdir "$build_dir/obj-$top" "${sources[@]}" "tb/$top.sv"
    (cd "$build_dir" && "$build_dir/obj-$top/V$top")
done
```

`--trace` supports the optional `+vcd` argument. Existing warnings include RTL/testbench
timescale differences and integer-to-counter-width conversions in the timer testbench.
They do not replace checking that compilation and every suite finish successfully.

## Verification coverage

The suites include a focused GPIO startup regression. Complete LOOP/PIN_CTRL
functional coverage remains deferred.

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

The datapath suite checks both registers, directions and every pin, synchronization
latency, output of the old register endpoint, untouched-pin retention and synchronous
reset priority. Core integration must still verify MOV followed by CMP, SET_DIR followed
by actual shifts, GPIO commit edges and flag retention across intervening instructions.
