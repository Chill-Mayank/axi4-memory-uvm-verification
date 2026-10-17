// =============================================================================
// axi_pkg.sv : UVM verification environment for axi_mem (UVM 1.1d / 1.2)
//
//   test
//    └─ env
//        ├─ agent ── sequencer ─> driver ─> (axi_if) ─> DUT
//        │           monitor  <── (axi_if)
//        ├─ scoreboard   (byte-level reference memory, checks every beat)
//        └─ coverage     (functional coverage of bursts, sizes, lengths, responses)
// =============================================================================
package axi_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_params_pkg::*;

  // ===========================================================================
  // Transaction: one complete AXI burst (write or read)
  // ===========================================================================
  class axi_txn extends uvm_sequence_item;
    // ---- request (randomized by sequences) ----
    rand bit              is_write;
    rand bit [ID_W-1:0]   id;
    rand bit [ADDR_W-1:0] addr;
    rand bit [7:0]        len;          // beats - 1
    rand bit [2:0]        size;         // bytes per beat = 2**size
    rand bit [1:0]        burst;
    bit [DATA_W-1:0]      data[];       // write data, one entry per beat (filled in post_randomize)
    bit [NB-1:0]          strb[];       // write strobes, one entry per beat
    rand bit              legal;        // 1 = request the slave supports
    rand bit              full_strb;    // 1 = enable every lane the beat uses
    rand int unsigned     valid_delay;  // idle cycles before VALID

    // ---- response (filled in by the driver / monitor) ----
    bit [1:0]             resp;         // BRESP, or RRESP of the first beat
    bit [1:0]             rresp[];      // per beat (reads)
    bit [ID_W-1:0]        rsp_id[];     // BID (1 entry) or RID per beat
    bit                   rlast_q[];    // RLAST per beat (reads)

    constraint c_legal_dist { legal dist {1 := 95, 0 := 5}; }
    constraint c_delay      { valid_delay dist {0 := 60, [1:3] := 40}; }
    constraint c_strb_dist  { full_strb dist {1 := 70, 0 := 30}; }

    constraint c_request {
      len <= 15;
      if (legal) {
        burst != RSVD;
        size  <= MAX_SIZE;
        if (burst == WRAP) {
          len inside {1, 3, 7, 15};
          (addr & ((8'd1 << size) - 8'd1)) == 0;
        }
        // keep INCR bursts inside the memory
        if (burst == INCR) int'(addr) + ((int'(len) + 1) << size) <= MEMSZ;
      } else {
        burst == RSVD || size > MAX_SIZE || (burst == WRAP && !(len inside {1, 3, 7, 15}));
      }
    }
    constraint c_order  { solve legal before burst, size, len; }

    // Build one data word and one strobe per beat. (Done here instead of with
    // array-size constraints, which not every simulator supports.)
    // Strobes may only enable lanes that the beat actually uses.
    function void post_randomize();
      data = new[int'(len) + 1];
      strb = new[int'(len) + 1];
      for (int i = 0; i <= len; i++) begin
        bit [NB-1:0] lanes = beat_lanes(addr, size, len, burst, i);
        for (int w = 0; w < DATA_W; w += 32) data[i][w +: 32] = $urandom;
        strb[i] = full_strb ? lanes : (NB'($urandom) & lanes);
      end
    endfunction

    `uvm_object_utils(axi_txn)
    function new(string name = "axi_txn");
      super.new(name);
    endfunction

    function string burst_name();
      case (burst) FIXED: return "FIXED"; INCR: return "INCR"; WRAP: return "WRAP"; default: return "RSVD"; endcase
    endfunction

    function string convert2string();
      return $sformatf("%s id=%0d addr=0x%02h len=%0d(%0d beats) size=%0d(%0dB) %s resp=%s",
                       is_write ? "WRITE" : "READ ", id, addr, len, len + 1, size, 1 << size,
                       burst_name(), resp == OKAY ? "OKAY" : "SLVERR");
    endfunction
  endclass

  // ===========================================================================
  // Driver: turns a transaction into wiggles on the AXI wires (master side)
  // Drives on the falling clock edge so the DUT always sees stable signals.
  // ===========================================================================
  class axi_driver extends uvm_driver #(axi_txn);
    `uvm_component_utils(axi_driver)
    virtual axi_if vif;
    int unsigned bready_pct = 70;     // % of cycles BREADY is high (back-pressure knob)
    int unsigned rready_pct = 75;     // % of cycles RREADY is high
    int unsigned wgap_pct   = 20;     // % chance of an idle gap before a W beat

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axi_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "virtual interface 'vif' not set")
      void'(uvm_config_db#(int unsigned)::get(this, "", "bready_pct", bready_pct));
      void'(uvm_config_db#(int unsigned)::get(this, "", "rready_pct", rready_pct));
      void'(uvm_config_db#(int unsigned)::get(this, "", "wgap_pct",   wgap_pct));
    endfunction

    task run_phase(uvm_phase phase);
      idle_bus();
      @(posedge vif.rst_n);
      forever begin
        seq_item_port.get_next_item(req);
        `uvm_info("DRV", {"start ", req.convert2string()}, UVM_HIGH)
        if (req.is_write) drive_write(req);
        else              drive_read(req);
        seq_item_port.item_done();
      end
    endtask

    function void idle_bus();
      vif.awvalid = 0; vif.wvalid = 0; vif.bready = 0; vif.arvalid = 0; vif.rready = 0;
      vif.awid = '0; vif.awaddr = '0; vif.awlen = '0; vif.awsize = '0; vif.awburst = '0;
      vif.wdata = '0; vif.wstrb = '0; vif.wlast = 0;
      vif.arid = '0; vif.araddr = '0; vif.arlen = '0; vif.arsize = '0; vif.arburst = '0;
    endfunction

    function bit coin(int unsigned pct);
      return ($urandom_range(99, 0) < pct);
    endfunction

    task drive_write(axi_txn t);
      // AW: VALID goes high on its own (never waits for READY), then holds
      repeat (t.valid_delay + 1) @(negedge vif.clk);
      vif.awid = t.id; vif.awaddr = t.addr; vif.awlen = t.len;
      vif.awsize = t.size; vif.awburst = t.burst; vif.awvalid = 1;
      while (!vif.awready) @(negedge vif.clk);
      @(negedge vif.clk);
      vif.awvalid = 0;
      // W beats
      for (int i = 0; i <= t.len; i++) begin
        if (coin(wgap_pct)) begin
          vif.wvalid = 0;
          repeat ($urandom_range(2, 1)) @(negedge vif.clk);
        end
        vif.wdata = t.data[i]; vif.wstrb = t.strb[i]; vif.wlast = (i == t.len); vif.wvalid = 1;
        while (!vif.wready) @(negedge vif.clk);
        @(negedge vif.clk);
      end
      vif.wvalid = 0; vif.wlast = 0;
      // B with random back-pressure
      forever begin
        vif.bready = coin(bready_pct);
        if (vif.bvalid && vif.bready) break;
        @(negedge vif.clk);
      end
      t.resp   = vif.bresp;
      t.rsp_id = new[1];
      t.rsp_id[0] = vif.bid;
      @(negedge vif.clk);
      vif.bready = 0;
    endtask

    task drive_read(axi_txn t);
      int beat = 0;
      repeat (t.valid_delay + 1) @(negedge vif.clk);
      vif.arid = t.id; vif.araddr = t.addr; vif.arlen = t.len;
      vif.arsize = t.size; vif.arburst = t.burst; vif.arvalid = 1;
      while (!vif.arready) @(negedge vif.clk);
      @(negedge vif.clk);
      vif.arvalid = 0;
      forever begin
        vif.rready = coin(rready_pct);
        if (vif.rvalid && vif.rready) begin
          if (beat == 0) t.resp = vif.rresp;
          if (vif.rlast) break;
          beat++;
        end
        @(negedge vif.clk);
      end
      @(negedge vif.clk);
      vif.rready = 0;
    endtask
  endclass

  // ===========================================================================
  // Monitor: watches the wires and rebuilds complete transactions.
  // It never drives anything, so it also works on a bus driven by real RTL.
  // ===========================================================================
  class axi_monitor extends uvm_monitor;
    `uvm_component_utils(axi_monitor)
    virtual axi_if vif;
    uvm_analysis_port #(axi_txn) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axi_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "virtual interface 'vif' not set")
    endfunction

    task run_phase(uvm_phase phase);
      fork
        watch_writes();
        watch_reads();
      join
    endtask

    task watch_writes();
      forever begin
        axi_txn t;
        bit [DATA_W-1:0] dq[$];
        bit [NB-1:0]     sq[$];
        // AW handshake
        do @(vif.mon_cb); while (!(vif.mon_cb.awvalid && vif.mon_cb.awready));
        t = axi_txn::type_id::create("wr");
        t.is_write = 1;
        t.id = vif.mon_cb.awid;   t.addr  = vif.mon_cb.awaddr; t.len = vif.mon_cb.awlen;
        t.size = vif.mon_cb.awsize; t.burst = vif.mon_cb.awburst;
        // W beats until WLAST
        forever begin
          @(vif.mon_cb);
          if (vif.mon_cb.wvalid && vif.mon_cb.wready) begin
            dq.push_back(vif.mon_cb.wdata);
            sq.push_back(vif.mon_cb.wstrb);
            if (vif.mon_cb.wlast) break;
          end
        end
        t.data = new[dq.size()];
        t.strb = new[sq.size()];
        foreach (dq[i]) begin t.data[i] = dq[i]; t.strb[i] = sq[i]; end
        // B handshake
        do @(vif.mon_cb); while (!(vif.mon_cb.bvalid && vif.mon_cb.bready));
        t.resp = vif.mon_cb.bresp;
        t.rsp_id = new[1];
        t.rsp_id[0] = vif.mon_cb.bid;
        `uvm_info("MON", t.convert2string(), UVM_MEDIUM)
        ap.write(t);
      end
    endtask

    task watch_reads();
      forever begin
        axi_txn t;
        bit [DATA_W-1:0] dq[$];
        bit [1:0]        rq[$];
        bit [ID_W-1:0]   iq[$];
        bit              lq[$];
        do @(vif.mon_cb); while (!(vif.mon_cb.arvalid && vif.mon_cb.arready));
        t = axi_txn::type_id::create("rd");
        t.is_write = 0;
        t.id = vif.mon_cb.arid;   t.addr  = vif.mon_cb.araddr; t.len = vif.mon_cb.arlen;
        t.size = vif.mon_cb.arsize; t.burst = vif.mon_cb.arburst;
        forever begin
          @(vif.mon_cb);
          if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
            dq.push_back(vif.mon_cb.rdata);
            rq.push_back(vif.mon_cb.rresp);
            iq.push_back(vif.mon_cb.rid);
            lq.push_back(vif.mon_cb.rlast);
            // stop on RLAST, or after 256 beats if RLAST never comes (scoreboard flags it)
            if (vif.mon_cb.rlast || dq.size() == 256) break;
          end
        end
        t.data    = new[dq.size()];
        t.rresp   = new[dq.size()];
        t.rsp_id  = new[dq.size()];
        t.rlast_q = new[dq.size()];
        foreach (dq[i]) begin
          t.data[i] = dq[i]; t.rresp[i] = rq[i]; t.rsp_id[i] = iq[i]; t.rlast_q[i] = lq[i];
        end
        t.resp = rq[0];
        `uvm_info("MON", t.convert2string(), UVM_MEDIUM)
        ap.write(t);
      end
    endtask
  endclass

  typedef uvm_sequencer #(axi_txn) axi_sequencer;

  // ===========================================================================
  // Agent: sequencer + driver + monitor in one box
  // ===========================================================================
  class axi_agent extends uvm_agent;
    `uvm_component_utils(axi_agent)
    axi_sequencer sqr;
    axi_driver    drv;
    axi_monitor   mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mon = axi_monitor::type_id::create("mon", this);
      if (get_is_active() == UVM_ACTIVE) begin
        sqr = axi_sequencer::type_id::create("sqr", this);
        drv = axi_driver::type_id::create("drv", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      if (get_is_active() == UVM_ACTIVE)
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // ===========================================================================
  // Scoreboard: keeps its own copy of memory and checks every response
  // ===========================================================================
  class axi_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(axi_scoreboard)
    uvm_analysis_imp #(axi_txn, axi_scoreboard) imp;

    bit [7:0] ref_mem [int];          // only bytes that have been written
    int n_writes, n_reads, n_slverr, n_bytes_checked, n_errors;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      imp = new("imp", this);
    endfunction

    function void fail(string msg, axi_txn t);
      n_errors++;
      `uvm_error("SCB", {msg, "  [", t.convert2string(), "]"})
    endfunction

    function void write(axi_txn t);
      bit exp_err   = is_illegal(t.addr, t.size, t.len, t.burst);
      bit [1:0] exp = exp_err ? SLVERR : OKAY;
      int beats     = int'(t.len) + 1;
      if (exp_err) n_slverr++;

      if (t.is_write) begin
        n_writes++;
        if (t.data.size() != beats)
          fail($sformatf("WLAST after %0d beats, AWLEN promised %0d", t.data.size(), beats), t);
        if (t.resp != exp)       fail($sformatf("BRESP=%0b expected %0b", t.resp, exp), t);
        if (t.rsp_id[0] != t.id) fail($sformatf("BID=%0d expected %0d", t.rsp_id[0], t.id), t);
        if (!exp_err)
          foreach (t.data[i]) begin
            int base = (beat_addr(t.addr, t.size, t.len, t.burst, i) / NB) * NB;
            for (int b = 0; b < NB; b++)
              if (t.strb[i][b]) ref_mem[(base + b) % MEMSZ] = t.data[i][8*b +: 8];
          end
      end
      else begin
        n_reads++;
        if (t.data.size() != beats)
          fail($sformatf("got %0d read beats, ARLEN asked for %0d", t.data.size(), beats), t);
        foreach (t.data[i]) begin
          bit [NB-1:0] lanes = beat_lanes(t.addr, t.size, t.len, t.burst, i);
          int base = (beat_addr(t.addr, t.size, t.len, t.burst, i) / NB) * NB;
          if (t.rresp[i] != exp)
            fail($sformatf("beat %0d RRESP=%0b expected %0b", i, t.rresp[i], exp), t);
          if (t.rsp_id[i] != t.id)
            fail($sformatf("beat %0d RID=%0d expected %0d", i, t.rsp_id[i], t.id), t);
          if (t.rlast_q[i] != (i == beats - 1))
            fail($sformatf("RLAST=%0b on beat %0d", t.rlast_q[i], i), t);
          if (!exp_err)
            for (int b = 0; b < NB; b++) begin
              int a = (base + b) % MEMSZ;
              if (lanes[b] && ref_mem.exists(a)) begin
                n_bytes_checked++;
                if (t.data[i][8*b +: 8] != ref_mem[a])
                  fail($sformatf("beat %0d byte 0x%02h: read %02h expected %02h",
                                 i, a, t.data[i][8*b +: 8], ref_mem[a]), t);
              end
            end
        end
      end
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("SCB", $sformatf("writes=%0d reads=%0d slverr=%0d bytes_checked=%0d errors=%0d",
                                 n_writes, n_reads, n_slverr, n_bytes_checked, n_errors), UVM_NONE)
      // A test that compared (almost) nothing must not pass silently
      if (n_bytes_checked < 4 * n_reads)
        `uvm_error("SCB", $sformatf("only %0d bytes compared for %0d reads - stimulus is broken",
                                    n_bytes_checked, n_reads))
      if (n_errors == 0 && n_reads > 0 && n_bytes_checked >= 4 * n_reads)
        `uvm_info("SCB", "*** TEST PASSED ***", UVM_NONE)
      else                              `uvm_error("SCB", "*** TEST FAILED ***")
    endfunction
  endclass

  // ===========================================================================
  // Functional coverage: "did we try every kind of burst?"
  // ===========================================================================
  class axi_coverage extends uvm_subscriber #(axi_txn);
    `uvm_component_utils(axi_coverage)
    axi_txn t;
    bit     unaligned;
    bit     partial_strb;

    covergroup cg;
      option.per_instance = 1;
      cp_dir   : coverpoint t.is_write { bins read = {0}; bins write = {1}; }
      cp_burst : coverpoint t.burst    { bins fixed = {FIXED}; bins incr = {INCR}; bins wrap = {WRAP}; bins rsvd = {RSVD}; }
      cp_size  : coverpoint t.size     { bins byte1 = {0}; bins byte2 = {1}; bins byte4 = {2}; bins too_big = {[3:7]}; }
      cp_len   : coverpoint t.len      { bins b1 = {0}; bins b2 = {1}; bins b4 = {3}; bins b8 = {7}; bins b16 = {15};
                                         bins b_other = {2, [4:6], [8:14]}; bins b_long = {[16:255]}; }
      cp_resp  : coverpoint t.resp     { bins okay = {OKAY}; bins slverr = {SLVERR}; }
      cp_unal  : coverpoint unaligned;
      cp_strb  : coverpoint partial_strb iff (t.is_write);
      x_dir_burst_size : cross cp_dir, cp_burst, cp_size;
      x_burst_len : cross cp_burst, cp_len {
        ignore_bins long_not_incr = binsof(cp_len.b_long) && !binsof(cp_burst.incr);
      }
      x_dir_resp : cross cp_dir, cp_resp;
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg = new();
    endfunction

    function void write(axi_txn t);
      this.t = t;
      unaligned = (t.addr % (1 << t.size)) != 0;
      partial_strb = 0;
      if (t.is_write)
        foreach (t.strb[i])
          if (t.strb[i] != beat_lanes(t.addr, t.size, t.len, t.burst, i)) partial_strb = 1;
      cg.sample();
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("COV", $sformatf("functional coverage = %0.1f%%", cg.get_inst_coverage()), UVM_NONE)
    endfunction
  endclass

  // ===========================================================================
  // Environment
  // ===========================================================================
  class axi_env extends uvm_env;
    `uvm_component_utils(axi_env)
    axi_agent      agt;
    axi_scoreboard scb;
    axi_coverage   cov;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agt = axi_agent::type_id::create("agt", this);
      scb = axi_scoreboard::type_id::create("scb", this);
      cov = axi_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      agt.mon.ap.connect(scb.imp);
      agt.mon.ap.connect(cov.analysis_export);
    endfunction
  endclass

  // ===========================================================================
  // Sequences
  // ===========================================================================

  // Base: helpers to send one write or read with chosen fields
  class axi_base_seq extends uvm_sequence #(axi_txn);
    `uvm_object_utils(axi_base_seq)
    function new(string name = "axi_base_seq");
      super.new(name);
    endfunction

    task send(axi_txn t);
      start_item(t);
      finish_item(t);
    endtask

    // Fully specified request; data is random, strobes full
    task do_req(bit wr, int a, int l, int s, int b, bit full = 1);
      axi_txn t = axi_txn::type_id::create("t");
      start_item(t);
      t.c_request.constraint_mode(0);          // allow anything, incl. illegal requests
      if (!t.randomize() with { is_write == wr; addr == a[ADDR_W-1:0]; len == l[7:0];
                                size == s[2:0]; burst == b[1:0]; full_strb == full; })
        `uvm_fatal("RAND", "randomize failed")
      finish_item(t);
    endtask
  endclass

  // Directed corner cases
  class axi_directed_seq extends axi_base_seq;
    `uvm_object_utils(axi_directed_seq)
    function new(string name = "axi_directed_seq");
      super.new(name);
    endfunction

    task body();
      //      wr addr len size burst
      do_req(1, 'h10,  3, 2, INCR);  do_req(0, 'h10,  3, 2, INCR);   // 4-word INCR
      do_req(1, 'h28,  3, 2, WRAP);  do_req(0, 'h28,  3, 2, WRAP);   // WRAP from mid-window
      do_req(0, 'h20,  3, 2, INCR);                                  //   ...read window in order
      do_req(1, 'h43,  5, 0, INCR);  do_req(0, 'h40,  3, 2, INCR);   // narrow, unaligned bytes
      do_req(1, 'h52,  3, 1, INCR);  do_req(0, 'h52,  3, 1, INCR);   // halfword burst
      do_req(1, 'h64,  3, 2, FIXED); do_req(0, 'h64,  0, 2, FIXED);  // FIXED: last beat wins
      do_req(1, 'h80,  1, 2, INCR, 0); do_req(0, 'h80, 1, 2, INCR);  // partial strobes
      do_req(1, 'hA0, 15, 2, WRAP);  do_req(0, 'hA0, 15, 2, WRAP);   // 16-beat wrap
      do_req(1, 'h00,255, 0, INCR);  do_req(0, 'h00,255, 0, INCR);   // 256-beat byte burst
      do_req(1, 'h10,  2, 2, WRAP);  do_req(0, 'h10,  3, 2, INCR);   // illegal WRAP len -> SLVERR, mem kept
      do_req(1, 'h12,  1, 2, WRAP);                                  // illegal WRAP unaligned
      do_req(1, 'h10,  0, 2, RSVD);  do_req(0, 'h10,  0, 2, RSVD);   // reserved burst type
      do_req(1, 'h10,  0, 3, INCR);  do_req(0, 'h10,  0, 3, INCR);   // size larger than bus
    endtask
  endclass

  // Random write followed by a read of exactly the same region
  class axi_wr_rd_seq extends axi_base_seq;
    `uvm_object_utils(axi_wr_rd_seq)
    int unsigned n = 200;
    function new(string name = "axi_wr_rd_seq");
      super.new(name);
    endfunction

    task body();
      repeat (n) begin
        axi_txn w = axi_txn::type_id::create("w");
        axi_txn r = axi_txn::type_id::create("r");
        start_item(w);
        if (!w.randomize() with { is_write == 1; }) `uvm_fatal("RAND", "randomize failed")
        finish_item(w);
        start_item(r);
        if (!r.randomize() with { is_write == 0; legal == w.legal; id == w.id; addr == w.addr;
                                  len == w.len; size == w.size; burst == w.burst; })
          `uvm_fatal("RAND", "randomize failed")
        finish_item(r);
      end
    endtask
  endclass

  // Fully random mix of reads and writes
  class axi_rand_seq extends axi_base_seq;
    `uvm_object_utils(axi_rand_seq)
    int unsigned n = 200;
    function new(string name = "axi_rand_seq");
      super.new(name);
    endfunction

    task body();
      repeat (n) begin
        axi_txn t = axi_txn::type_id::create("t");
        start_item(t);
        if (!t.randomize()) `uvm_fatal("RAND", "randomize failed")
        finish_item(t);
      end
    endtask
  endclass

  // ===========================================================================
  // Tests (pick one with +UVM_TESTNAME=<name>)
  // ===========================================================================
  class axi_base_test extends uvm_test;
    `uvm_component_utils(axi_base_test)
    axi_env env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = axi_env::type_id::create("env", this);
      uvm_top.set_timeout(20ms, 1);          // a hung DUT ends the test with UVM_FATAL
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      uvm_top.print_topology();
    endfunction

    virtual task run_seqs();
    endtask

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      run_seqs();
      #100ns;
      phase.drop_objection(this);
    endtask
  endclass

  // Directed corner cases only
  class axi_directed_test extends axi_base_test;
    `uvm_component_utils(axi_directed_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task run_seqs();
      axi_directed_seq s = axi_directed_seq::type_id::create("s");
      s.start(env.agt.sqr);
    endtask
  endclass

  // Main regression test: directed + write/read-back + random mix
  class axi_rand_test extends axi_base_test;
    `uvm_component_utils(axi_rand_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task run_seqs();
      axi_directed_seq d  = axi_directed_seq::type_id::create("d");
      axi_wr_rd_seq    wr = axi_wr_rd_seq::type_id::create("wr");
      axi_rand_seq     r  = axi_rand_seq::type_id::create("r");
      d.start(env.agt.sqr);
      wr.n = 300; wr.start(env.agt.sqr);
      r.n  = 300; r.start(env.agt.sqr);
    endtask
  endclass

  // Same as axi_rand_test but the master is slow to accept responses
  class axi_backpressure_test extends axi_rand_test;
    `uvm_component_utils(axi_backpressure_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      uvm_config_db#(int unsigned)::set(this, "*", "bready_pct", 20);
      uvm_config_db#(int unsigned)::set(this, "*", "rready_pct", 20);
      uvm_config_db#(int unsigned)::set(this, "*", "wgap_pct",   50);
      super.build_phase(phase);
    endfunction
  endclass
endpackage
