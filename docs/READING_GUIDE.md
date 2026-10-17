# How to read this code (suggested order)

Don't start with the biggest file. Go in this order — each step only needs
what you learned in the step before.

| # | Open this | Look for | Why |
|---|-----------|----------|-----|
| 1 | [`docs/AXI_BASICS.md`](AXI_BASICS.md) | handshake, bursts, the waveform at the end | the protocol in plain words |
| 2 | [`learning/`](../learning/) | the small files in order | tiny examples, one idea each |
| 3 | [`rtl/axi_mem.sv`](../rtl/axi_mem.sv) | the **port list** first | which wires go in and out |
| 4 | same file | `WRITE PATH` section | write state machine: IDLE → DATA → RESP |
| 5 | same file | `READ PATH` section | read state machine: IDLE → DATA |
| 6 | same file | `next_addr` function | how FIXED / INCR / WRAP addresses move |
| 7 | [`tb/tb_smoke.sv`](../tb/tb_smoke.sv) | tasks `axi_write` and `axi_read` | a simple testbench *without* UVM — easiest way to see how the DUT is driven |
| 8 | [`tb/axi_sva.sv`](../tb/axi_sva.sv) | the `AXI_HOLD` rules | how assertions describe protocol rules |
| 9 | [`tb/axi_pkg.sv`](../tb/axi_pkg.sv) | classes in this order: `axi_txn` → `axi_driver` → `axi_monitor` → `axi_scoreboard` → `axi_coverage` → sequences → tests | the UVM testbench, one piece at a time |
| 10 | [`tb/tb_top.sv`](../tb/tb_top.sv) | `run_test` | how everything is connected and started |

## Tips

* Run the test first, then read the code. Seeing `TEST PASSED` and a waveform
  makes the code much easier to follow.
* Open the waveform (`./run_uvm.sh axi_rand_test 1 gui`) next to the RTL and
  match each signal to the line of code that drives it.
* Try breaking something on purpose — e.g. change `wstrb[b]` to `1'b1` in
  `axi_mem.sv` — and watch the scoreboard catch it. Then undo the change.
