// =============================================================================
// axi_sva.sv : AXI4 protocol checker (SystemVerilog Assertions)
//
// Bound into every axi_mem instance with 'bind' (bottom of this file), so it
// watches the DUT ports in any testbench without touching the RTL.
//   * Master rules  : catch a broken testbench / master
//   * Slave rules   : catch a broken DUT
//   * Cover points  : prove interesting scenarios really happened
// =============================================================================
module axi_sva #(
  parameter int DATA_W = 32,
  parameter int ADDR_W = 8,
  parameter int ID_W   = 4
)(
  input logic                clk, rst_n,
  input logic [ID_W-1:0]     awid,   input logic [ADDR_W-1:0] awaddr, input logic [7:0] awlen,
  input logic [2:0]          awsize, input logic [1:0] awburst, input logic awvalid, input logic awready,
  input logic [DATA_W-1:0]   wdata,  input logic [DATA_W/8-1:0] wstrb, input logic wlast,
  input logic                wvalid, input logic wready,
  input logic [ID_W-1:0]     bid,    input logic [1:0] bresp, input logic bvalid, input logic bready,
  input logic [ID_W-1:0]     arid,   input logic [ADDR_W-1:0] araddr, input logic [7:0] arlen,
  input logic [2:0]          arsize, input logic [1:0] arburst, input logic arvalid, input logic arready,
  input logic [ID_W-1:0]     rid,    input logic [DATA_W-1:0] rdata, input logic [1:0] rresp,
  input logic                rlast,  input logic rvalid, input logic rready
);

  // "Once VALID is high it stays high, with the same payload, until READY"
  `define AXI_HOLD(NAME, VALID, READY, PAYLOAD)                                   \
    NAME: assert property (@(posedge clk) disable iff (!rst_n)                    \
            (VALID && !READY) |=> (VALID && $stable(PAYLOAD)))                    \
          else $error(`"AXI rule broken: NAME (VALID dropped or payload changed before READY)`");

  // ---------------- handshake rules (AXI4 spec A3.2.1) ----------------
  `AXI_HOLD(a_aw_hold, awvalid, awready, {awid, awaddr, awlen, awsize, awburst})
  `AXI_HOLD(a_w_hold,  wvalid,  wready,  {wdata, wstrb, wlast})
  `AXI_HOLD(a_ar_hold, arvalid, arready, {arid, araddr, arlen, arsize, arburst})
  `AXI_HOLD(a_b_hold,  bvalid,  bready,  {bid, bresp})
  `AXI_HOLD(a_r_hold,  rvalid,  rready,  {rid, rdata, rresp, rlast})

  a_no_x_ctrl: assert property (@(posedge clk) disable iff (!rst_n)
      !$isunknown({awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready}))
    else $error("X/Z on an AXI VALID or READY");

  // ---------------- bookkeeping for burst-level rules ----------------
  logic [7:0]      aw_len_q, ar_len_q;
  logic [ID_W-1:0] aw_id_q,  ar_id_q;
  logic [1:0]      aw_burst_q;
  logic [8:0]      w_beats,  r_beats;
  logic            w_done,   ar_open;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_len_q <= '0; ar_len_q <= '0; aw_id_q <= '0; ar_id_q <= '0; aw_burst_q <= '0;
      w_beats  <= '0; r_beats  <= '0; w_done  <= 1'b0; ar_open <= 1'b0;
    end
    else begin
      if (awvalid && awready) begin
        aw_len_q <= awlen; aw_id_q <= awid; aw_burst_q <= awburst; w_beats <= '0; w_done <= 1'b0;
      end
      else if (wvalid && wready) begin
        w_beats <= w_beats + 9'd1;
        if (wlast) w_done <= 1'b1;
      end
      if (bvalid && bready) w_done <= 1'b0;

      if (arvalid && arready) begin
        ar_len_q <= arlen; ar_id_q <= arid; r_beats <= '0; ar_open <= 1'b1;
      end
      else if (rvalid && rready) begin
        r_beats <= r_beats + 9'd1;
        if (rlast) ar_open <= 1'b0;
      end
    end
  end

  // ---------------- burst rules ----------------
  // Master: WLAST exactly on beat AWLEN+1
  a_wlast_position: assert property (@(posedge clk) disable iff (!rst_n)
      (wvalid && wready) |-> (wlast == (w_beats == {1'b0, aw_len_q})))
    else $error("WLAST not on beat AWLEN+1 (beat %0d, awlen %0d)", w_beats, aw_len_q);

  // Slave: write response only after the last data beat, with the right ID
  a_b_after_wlast: assert property (@(posedge clk) disable iff (!rst_n) bvalid |-> w_done)
    else $error("BVALID before the last write data beat");
  a_bid_match: assert property (@(posedge clk) disable iff (!rst_n) bvalid |-> (bid == aw_id_q))
    else $error("BID %0d does not match AWID %0d", bid, aw_id_q);

  // Slave: read data only for an accepted request, right ID, RLAST on beat ARLEN+1
  a_r_needs_ar: assert property (@(posedge clk) disable iff (!rst_n) rvalid |-> ar_open)
    else $error("RVALID without an outstanding read request");
  a_rid_match: assert property (@(posedge clk) disable iff (!rst_n) rvalid |-> (rid == ar_id_q))
    else $error("RID %0d does not match ARID %0d", rid, ar_id_q);
  a_rlast_position: assert property (@(posedge clk) disable iff (!rst_n)
      rvalid |-> (rlast == (r_beats == {1'b0, ar_len_q})))
    else $error("RLAST wrong on read beat %0d (arlen %0d)", r_beats, ar_len_q);

  // Slave: only OKAY or SLVERR, and SLVERR for a reserved burst type
  a_bresp_legal: assert property (@(posedge clk) disable iff (!rst_n)
      bvalid |-> (bresp == 2'b00 || bresp == 2'b10))
    else $error("BRESP other than OKAY/SLVERR");
  a_rresp_legal: assert property (@(posedge clk) disable iff (!rst_n)
      rvalid |-> (rresp == 2'b00 || rresp == 2'b10))
    else $error("RRESP other than OKAY/SLVERR");
  a_rsvd_slverr: assert property (@(posedge clk) disable iff (!rst_n)
      (bvalid && aw_burst_q == 2'b11) |-> (bresp == 2'b10))
    else $error("reserved burst type did not get SLVERR");

  // ---------------- coverage of interesting protocol situations ----------------
  c_aw_wait:   cover property (@(posedge clk) disable iff (!rst_n) awvalid && !awready);
  c_b_stall:   cover property (@(posedge clk) disable iff (!rst_n) bvalid && !bready);
  c_r_stall:   cover property (@(posedge clk) disable iff (!rst_n) rvalid && !rready);
  c_w_gap:     cover property (@(posedge clk) disable iff (!rst_n) wready && !wvalid);
  c_rd_wr_overlap: cover property (@(posedge clk) disable iff (!rst_n) (wvalid && wready) && (rvalid && rready));
  c_wrap_done: cover property (@(posedge clk) disable iff (!rst_n) bvalid && bready && aw_burst_q == 2'b10);
  c_slverr:    cover property (@(posedge clk) disable iff (!rst_n) bvalid && bready && bresp == 2'b10);
  c_long_read: cover property (@(posedge clk) disable iff (!rst_n) rvalid && rready && rlast && ar_len_q == 8'd255);

  `undef AXI_HOLD
endmodule

// Attach the checker to every axi_mem, connecting ports by name
bind axi_mem axi_sva #(.DATA_W(DATA_W), .ADDR_W(ADDR_W), .ID_W(ID_W)) u_axi_sva (.*);
