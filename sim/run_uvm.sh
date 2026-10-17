#!/bin/bash
# Run one UVM test on Cadence Xcelium.
#   ./run_uvm.sh                              axi_rand_test, random seed
#   ./run_uvm.sh axi_directed_test            pick a test
#   ./run_uvm.sh axi_rand_test 1234           fixed seed (to reproduce a failure)
#   ./run_uvm.sh axi_rand_test 1234 gui       open SimVision
# Tests: axi_directed_test  axi_rand_test  axi_backpressure_test
cd "$(dirname "$0")"
TEST=${1:-axi_rand_test}
SEED=${2:-random}
GUI=""; [ "$3" == "gui" ] && GUI="-gui +WAVES"
mkdir -p logs
xrun -uvm -sv -access +rwc -timescale 1ns/1ps \
     -f files.f -top tb_top \
     +UVM_TESTNAME=$TEST +UVM_VERBOSITY=UVM_LOW -svseed $SEED \
     -coverage all -covoverwrite -covtest ${TEST}_${SEED} \
     -l logs/${TEST}.log $GUI
echo "---------------- summary ----------------"
grep -E "UVM_(ERROR|FATAL) :|TEST PASSED|TEST FAILED|functional coverage|SVSEED|bytes_checked" logs/${TEST}.log
