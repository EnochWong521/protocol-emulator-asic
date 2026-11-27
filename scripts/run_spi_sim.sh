#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/protocol-spi-XXXXXX")
sources=(isa_pkg pc inst_fetch control_unit register_file shift_datapath
         cmp_datapath wait_timer protocol_core)
rtl=()
for source in "${sources[@]}"; do rtl+=("$repo_dir/rtl/$source.sv"); done

if ! iverilog -g2012 -s tb_spi -o "$build_dir/tb_spi.vvp" \
    "${rtl[@]}" "$repo_dir/tb/tb_spi.sv" >"$build_dir/compile.log" 2>&1; then
    cat "$build_dir/compile.log"
    exit 1
fi
printf 'SPI simulation artifacts: %s\n' "$build_dir"
cd -- "$build_dir"
vvp ./tb_spi.vvp "+spi_program=$repo_dir/examples/spi_mode0.hex" "$@"
