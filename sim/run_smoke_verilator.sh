#!/bin/bash
# Run the simple (non-UVM) test with the FREE simulator Verilator (version 5+).
# No Cadence licence needed.  Install on Ubuntu:  sudo apt install verilator
# (UVM tests still need a commercial simulator such as Cadence Xcelium.)
cd "$(dirname "$0")"
verilator --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  --top-module tb_smoke ../rtl/axi_mem.sv ../tb/axi_sva.sv ../tb/tb_smoke.sv \
  -Mdir obj_smoke -o tb_smoke > verilator_build.log 2>&1 || { echo "build failed, see sim/verilator_build.log"; exit 1; }
./obj_smoke/tb_smoke | tail -6
