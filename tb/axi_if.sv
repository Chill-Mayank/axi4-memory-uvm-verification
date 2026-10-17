// =============================================================================
// axi_if.sv : the bundle of AXI wires between the testbench and the DUT.
//   * The driver writes the master-side signals directly (on the falling edge).
//   * The monitor reads everything through mon_cb, which samples values just
//     before each rising edge (exactly what the DUT saw).
// =============================================================================
interface axi_if (input logic clk, input logic rst_n);
  import axi_params_pkg::*;

  // Write address
  logic [ID_W-1:0]   awid;
  logic [ADDR_W-1:0] awaddr;
  logic [7:0]        awlen;
  logic [2:0]        awsize;
  logic [1:0]        awburst;
  logic              awvalid, awready;
  // Write data
  logic [DATA_W-1:0] wdata;
  logic [NB-1:0]     wstrb;
  logic              wlast, wvalid, wready;
  // Write response
  logic [ID_W-1:0]   bid;
  logic [1:0]        bresp;
  logic              bvalid, bready;
  // Read address
  logic [ID_W-1:0]   arid;
  logic [ADDR_W-1:0] araddr;
  logic [7:0]        arlen;
  logic [2:0]        arsize;
  logic [1:0]        arburst;
  logic              arvalid, arready;
  // Read data
  logic [ID_W-1:0]   rid;
  logic [DATA_W-1:0] rdata;
  logic [1:0]        rresp;
  logic              rlast, rvalid, rready;

  clocking mon_cb @(posedge clk);
    default input #1step;
    input awid, awaddr, awlen, awsize, awburst, awvalid, awready;
    input wdata, wstrb, wlast, wvalid, wready;
    input bid, bresp, bvalid, bready;
    input arid, araddr, arlen, arsize, arburst, arvalid, arready;
    input rid, rdata, rresp, rlast, rvalid, rready;
  endclocking
endinterface
