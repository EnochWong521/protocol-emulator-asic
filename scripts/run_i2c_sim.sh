#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/protocol-i2c-XXXXXX")
sources=(isa_pkg pc inst_fetch control_unit register_file shift_datapath
         cmp_datapath wait_timer protocol_core)
rtl=()
for source in "${sources[@]}"; do rtl+=("$repo_dir/rtl/$source.sv"); done

printf 'I2C simulation artifacts: %s\n' "$build_dir"
for top in tb_pin_mode tb_i2c; do
    if ! iverilog -g2012 -s "$top" -o "$build_dir/$top.vvp" \
        "${rtl[@]}" "$repo_dir/tb/$top.sv" >"$build_dir/$top-compile.log" 2>&1; then
        cat "$build_dir/$top-compile.log"
        exit 1
    fi
done
cd -- "$build_dir"
vvp ./tb_pin_mode.vvp
vvp ./tb_i2c.vvp "+i2c_program=$repo_dir/examples/i2c_write_read.hex" "$@"
