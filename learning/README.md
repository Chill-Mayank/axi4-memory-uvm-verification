# My learning path

These are the small practice files I wrote, ran and debugged on the lab's
Cadence Xcelium server while learning Verilog and AXI from scratch. Each step
added one new idea.

| Step | File               | What I learned |
|------|--------------------|----------------|
| 1    | `hello.sv`         | first simulation: `module`, `initial`, `$display` |
| 2    | `and_tb.sv`        | a design + testbench, `assign`, checking outputs, X values |
| 3    | `step1.sv`         | `always_ff`, clock, `<=` |
| 4    | `handshake_tb.sv`  | the VALID/READY handshake on one channel |
| 5    | `axi_write.sv`     | a single-beat AXI write (AW, W, B) |
| 6    | `axi_rw.sv`        | single-beat write and read with a self-checking test |
| 7    | `axi_burst.sv`     | burst write: AWLEN, WLAST, one B response per burst |
| 8    | `../rtl`, `../tb`  | full AXI4 slave + UVM testbench |

Mistakes I made along the way (and what they taught me):

* declared an output as `input` → the signal stayed X
* forgot `endmodule` → `EOFMOD` compile error
* typed `@posedge clk)` instead of `@(posedge clk)` → syntax error
* pasted code into the `xcelium>` prompt instead of a file
* pressed Run after `$finish` → "terminated abnormally"
