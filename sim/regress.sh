#!/bin/bash
# Mini regression: every test with several random seeds, then a pass/fail table.
cd "$(dirname "$0")"
mkdir -p logs
TESTS="axi_directed_test axi_rand_test axi_backpressure_test"
SEEDS=${SEEDS:-"1 2 3 4 5"}
pass=0; fail=0
for t in $TESTS; do
  for s in $SEEDS; do
    xrun -uvm -sv -timescale 1ns/1ps -f files.f -top tb_top \
         +UVM_TESTNAME=$t +UVM_VERBOSITY=UVM_NONE -svseed $s \
         -coverage all -covoverwrite -covtest ${t}_${s} -l logs/${t}_${s}.log >/dev/null 2>&1
    if grep -q "TEST PASSED" logs/${t}_${s}.log && grep -q "UVM_ERROR :    0" logs/${t}_${s}.log; then
      echo "PASS  $t  seed=$s"; pass=$((pass+1))
    else
      echo "FAIL  $t  seed=$s   (see sim/logs/${t}_${s}.log)"; fail=$((fail+1))
    fi
  done
done
echo "======== $pass passed, $fail failed ========"
echo "Merged coverage:  imc -gui   then load cov_work/scope/*"
