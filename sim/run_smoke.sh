#!/bin/bash
# Quick non-UVM test (+ SVA checker) on Cadence Xcelium.
#   ./run_smoke.sh          batch run
#   ./run_smoke.sh gui      open SimVision
cd "$(dirname "$0")"
mkdir -p logs
GUI=""; [ "$1" == "gui" ] && GUI="-gui"
xrun -sv -access +rwc -timescale 1ns/1ps \
     ../rtl/axi_mem.sv ../tb/axi_sva.sv ../tb/tb_smoke.sv -top tb_smoke \
     -svseed random -l logs/smoke.log $GUI
grep -E "TEST PASSED|TEST FAILED|TIMEOUT" logs/smoke.log
