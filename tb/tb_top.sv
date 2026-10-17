// =============================================================================
// tb_top.sv : top module for the UVM testbench
// =============================================================================
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*;
  import axi_params_pkg::*;
  import axi_pkg::*;

  logic clk = 0;
  logic rst_n;
  always #5 clk = ~clk;                       // 100 MHz

  initial begin
    rst_n = 0;
    repeat (5) @(negedge clk);
    rst_n = 1;
  end

  axi_if vif (.clk(clk), .rst_n(rst_n));

  axi_mem #(.DATA_W(DATA_W), .ADDR_W(ADDR_W), .ID_W(ID_W)) dut (
    .clk     (clk),          .rst_n   (rst_n),
    .awid    (vif.awid),     .awaddr  (vif.awaddr),  .awlen   (vif.awlen),
    .awsize  (vif.awsize),   .awburst (vif.awburst), .awvalid (vif.awvalid), .awready (vif.awready),
    .wdata   (vif.wdata),    .wstrb   (vif.wstrb),   .wlast   (vif.wlast),
    .wvalid  (vif.wvalid),   .wready  (vif.wready),
    .bid     (vif.bid),      .bresp   (vif.bresp),   .bvalid  (vif.bvalid),  .bready  (vif.bready),
    .arid    (vif.arid),     .araddr  (vif.araddr),  .arlen   (vif.arlen),
    .arsize  (vif.arsize),   .arburst (vif.arburst), .arvalid (vif.arvalid), .arready (vif.arready),
    .rid     (vif.rid),      .rdata   (vif.rdata),   .rresp   (vif.rresp),
    .rlast   (vif.rlast),    .rvalid  (vif.rvalid),  .rready  (vif.rready)
  );

  initial begin
    uvm_config_db#(virtual axi_if)::set(null, "uvm_test_top.*", "vif", vif);
    run_test("axi_rand_test");               // override with +UVM_TESTNAME=...
  end

  // Waveform dump for SimVision: run with +WAVES
  initial if ($test$plusargs("WAVES")) begin
`ifdef VERILATOR
    $dumpfile("waves.vcd");
    $dumpvars(0, tb_top);
`else
    $shm_open("waves.shm");                  // Cadence waveform database
    $shm_probe(tb_top, "AS");
`endif
  end
endmodule
