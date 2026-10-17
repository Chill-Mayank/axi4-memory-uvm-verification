// =============================================================================
// tb_smoke.sv : self-checking directed + random testbench (no UVM)
//
// A quick test that runs on any SystemVerilog simulator. It drives AXI4 bursts
// with random VALID delays and random BREADY/RREADY back-pressure, keeps its
// own byte-level reference memory, and compares every read beat against it.
// The reference address math is written independently of the RTL.
// =============================================================================
`timescale 1ns/1ps
module tb_smoke;
  localparam int DATA_W = 32;
  localparam int ADDR_W = 8;
  localparam int ID_W   = 4;
  localparam int NB     = DATA_W/8;
  localparam int MEMSZ  = 1 << ADDR_W;
  localparam int N_RANDOM = 400;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n;

  // AXI wires
  logic [ID_W-1:0]   awid = '0;   logic [ADDR_W-1:0] awaddr = '0; logic [7:0] awlen = '0;
  logic [2:0]        awsize = '0; logic [1:0] awburst = '0;      logic awvalid = 0; logic awready;
  logic [DATA_W-1:0] wdata = '0;  logic [NB-1:0] wstrb = '0;      logic wlast = 0; logic wvalid = 0; logic wready;
  logic [ID_W-1:0]   bid;         logic [1:0] bresp;              logic bvalid; logic bready = 0;
  logic [ID_W-1:0]   arid = '0;   logic [ADDR_W-1:0] araddr = '0; logic [7:0] arlen = '0;
  logic [2:0]        arsize = '0; logic [1:0] arburst = '0;      logic arvalid = 0; logic arready;
  logic [ID_W-1:0]   rid;         logic [DATA_W-1:0] rdata;       logic [1:0] rresp; logic rlast; logic rvalid; logic rready = 0;

  axi_mem #(.DATA_W(DATA_W), .ADDR_W(ADDR_W), .ID_W(ID_W)) dut (.*);

  // ---------------- reference model ----------------
  logic [7:0] ref_mem   [0:MEMSZ-1];
  bit         ref_valid [0:MEMSZ-1];     // byte has been written at least once
  int n_checks = 0, n_errors = 0, n_writes = 0, n_reads = 0;

  // Address of beat 'beat' in a burst (computed beat by beat, from the spec)
  function automatic int beat_addr(int start, int size, int len, int burst, int beat);
    int a = start;
    int bytes = 1 << size;
    for (int i = 0; i < beat; i++) begin
      if (burst == 0) a = a;                                         // FIXED
      else if (burst == 2) begin                                     // WRAP
        int total = (len + 1) * bytes;
        int lower = (a / total) * total;
        a = (a / bytes) * bytes + bytes;
        if (a >= lower + total) a = lower;
      end
      else a = (a / bytes) * bytes + bytes;                          // INCR
    end
    return a % MEMSZ;
  endfunction

  // Byte lanes that belong to beat 'beat'
  function automatic logic [NB-1:0] beat_lanes(int start, int size, int len, int burst, int beat);
    int a     = beat_addr(start, size, len, burst, beat);
    int bytes = 1 << size;
    int lo    = a % NB;
    int hi    = ((a / bytes) * bytes) % NB + bytes - 1;
    logic [NB-1:0] m = '0;
    for (int b = lo; b <= hi; b++) m[b] = 1'b1;
    return m;
  endfunction

  function automatic bit illegal(int start, int size, int len, int burst);
    if (burst == 3) return 1;
    if ((1 << size) > NB) return 1;
    if (burst == 2 && !(len == 1 || len == 3 || len == 7 || len == 15)) return 1;
    if (burst == 2 && (start % (1 << size)) != 0) return 1;
    return 0;
  endfunction

  // ---------------- master tasks ----------------
  logic [DATA_W-1:0] wbuf [0:255];
  logic [NB-1:0]     sbuf [0:255];

  // The TB drives and samples only on the FALLING edge of clk. The DUT works on
  // the RISING edge, so every signal is stable when the DUT looks at it (no race).
  task automatic wait_cycles(int n);
    repeat (n) @(negedge clk);
  endtask

  task automatic axi_write(int id, int addr, int len, int size, int burst);
    bit exp_err = illegal(addr, size, len, burst);
    // ---- AW: hold VALID and the address until READY ----
    wait_cycles($urandom_range(1, 3));
    awid = ID_W'(id); awaddr = ADDR_W'(addr); awlen = 8'(len);
    awsize = 3'(size); awburst = 2'(burst); awvalid = 1;
    while (!awready) @(negedge clk);
    @(negedge clk);                      // handshake happened on the rising edge in between
    awvalid = 0;
    // ---- W: one beat per handshake, random idle gaps ----
    for (int i = 0; i <= len; i++) begin
      if ($urandom_range(0, 3) == 0) begin wvalid = 0; wait_cycles($urandom_range(1, 2)); end
      wvalid = 1; wdata = wbuf[i]; wstrb = sbuf[i]; wlast = (i == len);
      while (!wready) @(negedge clk);
      @(negedge clk);
    end
    wvalid = 0; wlast = 0;
    // ---- B: random back-pressure on BREADY ----
    forever begin
      bready = ($urandom_range(0, 2) != 0);
      if (bvalid && bready) break;
      @(negedge clk);
    end
    n_checks++;
    if (bid !== ID_W'(id)) begin n_errors++; $display("ERROR: BID %0d expected %0d", bid, id); end
    n_checks++;
    if (bresp !== (exp_err ? 2'b10 : 2'b00)) begin
      n_errors++; $display("ERROR: BRESP %0b expected %0b (addr %0d len %0d size %0d burst %0d)",
                           bresp, exp_err ? 2'b10 : 2'b00, addr, len, size, burst);
    end
    @(negedge clk);
    bready = 0;
    n_writes++;
    // ---- update the reference model ----
    if (!exp_err) begin
      for (int i = 0; i <= len; i++) begin
        int a = beat_addr(addr, size, len, burst, i);
        int base = (a / NB) * NB;
        for (int b = 0; b < NB; b++)
          if (sbuf[i][b]) begin
            ref_mem[(base + b) % MEMSZ]   = wbuf[i][8*b +: 8];
            ref_valid[(base + b) % MEMSZ] = 1;
          end
      end
    end
  endtask

  task automatic axi_read(int id, int addr, int len, int size, int burst);
    bit exp_err = illegal(addr, size, len, burst);
    int beat = 0;
    wait_cycles($urandom_range(1, 3));
    arid = ID_W'(id); araddr = ADDR_W'(addr); arlen = 8'(len);
    arsize = 3'(size); arburst = 2'(burst); arvalid = 1;
    while (!arready) @(negedge clk);
    @(negedge clk);
    arvalid = 0;
    forever begin
      rready = ($urandom_range(0, 3) != 0);
      if (rvalid && rready) begin
        logic [NB-1:0] lanes = beat_lanes(addr, size, len, burst, beat);
        int a    = beat_addr(addr, size, len, burst, beat);
        int base = (a / NB) * NB;
        n_checks++;
        if (rid !== ID_W'(id))  begin n_errors++; $display("ERROR: RID %0d expected %0d", rid, id); end
        n_checks++;
        if (rresp !== (exp_err ? 2'b10 : 2'b00)) begin n_errors++; $display("ERROR: RRESP %0b", rresp); end
        n_checks++;
        if (rlast !== (beat == len)) begin n_errors++; $display("ERROR: RLAST=%0b on beat %0d of %0d", rlast, beat, len); end
        if (!exp_err)
          for (int b = 0; b < NB; b++)
            if (lanes[b] && ref_valid[(base + b) % MEMSZ]) begin
              n_checks++;
              if (rdata[8*b +: 8] !== ref_mem[(base + b) % MEMSZ]) begin
                n_errors++;
                $display("ERROR: read addr %0d lane %0d got %h expected %h (start %0d len %0d size %0d burst %0d beat %0d)",
                         base + b, b, rdata[8*b +: 8], ref_mem[(base + b) % MEMSZ], addr, len, size, burst, beat);
              end
            end
        if (rlast) break;
        beat++;
      end
      @(negedge clk);
    end
    @(negedge clk);
    rready = 0;
    n_reads++;
  endtask

  // Fill write buffers with random data and legal strobes
  task automatic make_write_data(int addr, int len, int size, int burst, bit full_strobe);
    for (int i = 0; i <= len; i++) begin
      logic [NB-1:0] lanes = beat_lanes(addr, size, len, burst, i);
      wbuf[i] = $urandom;
      sbuf[i] = full_strobe ? lanes : (lanes & NB'($urandom));
    end
  endtask

  // Pick a random legal request (or occasionally an illegal one)
  task automatic random_req(output int addr, output int len, output int size, output int burst);
    int r = $urandom_range(0, 99);
    size  = $urandom_range(0, $clog2(NB));
    if (r < 25)      burst = 0;      // FIXED
    else if (r < 70) burst = 1;      // INCR
    else if (r < 95) burst = 2;      // WRAP
    else             burst = 3;      // reserved -> SLVERR
    case (burst)
      2: begin
        int opts[4] = '{1, 3, 7, 15};
        len  = opts[$urandom_range(0, 3)];
        addr = ($urandom_range(0, MEMSZ - 1) >> size) << size;    // aligned
      end
      1: begin
        len  = $urandom_range(0, 15);
        // keep INCR inside memory
        addr = $urandom_range(0, MEMSZ - (len + 1) * (1 << size));
      end
      default: begin
        len  = $urandom_range(0, 7);
        addr = $urandom_range(0, MEMSZ - 1);
      end
    endcase
  endtask

  // ---------------- test sequence ----------------
  initial begin
    int addr, len, size, burst;
    rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;

    // ---- Directed tests ----
    // 1. INCR burst of 4 words at address 0x10
    make_write_data(16, 3, 2, 1, 1); axi_write(1, 16, 3, 2, 1); axi_read(1, 16, 3, 2, 1);
    // 2. WRAP burst of 4 words starting in the middle of its 16-byte window
    make_write_data(40, 3, 2, 2, 1); axi_write(2, 40, 3, 2, 2); axi_read(2, 32, 3, 2, 1);
    // 3. Narrow byte INCR burst, unaligned start
    make_write_data(67, 5, 0, 1, 1); axi_write(3, 67, 5, 0, 1); axi_read(3, 64, 3, 2, 1);
    // 4. FIXED burst: 4 beats to the same word, last one wins
    make_write_data(100, 3, 2, 0, 1); axi_write(4, 100, 3, 2, 0); axi_read(4, 100, 0, 2, 0);
    // 5. Partial strobes
    make_write_data(128, 1, 2, 1, 0); axi_write(5, 128, 1, 2, 1); axi_read(5, 128, 1, 2, 1);
    // 6. Illegal requests -> SLVERR, memory unchanged
    make_write_data(16, 2, 2, 2, 1); axi_write(6, 16, 2, 2, 2);   // WRAP with 3 beats
    axi_read(6, 16, 3, 2, 1);                                    // data must be unchanged
    make_write_data(16, 0, 2, 3, 1); axi_write(7, 16, 0, 2, 3);   // reserved burst type
    axi_read(7, 16, 0, 2, 3);                                    // read SLVERR
    $display("Directed tests done: %0d checks, %0d errors", n_checks, n_errors);

    // ---- Constrained random: write then read back the same region ----
    for (int t = 0; t < N_RANDOM; t++) begin
      random_req(addr, len, size, burst);
      make_write_data(addr, len, size, burst, $urandom_range(0, 1));
      axi_write(t % 16, addr, len, size, burst);
      if ($urandom_range(0, 1)) axi_read(t % 16, addr, len, size, burst);
      else begin
        random_req(addr, len, size, burst);
        axi_read(t % 16, addr, len, size, burst);
      end
    end

    $display("==================================================");
    $display(" writes=%0d reads=%0d checks=%0d errors=%0d", n_writes, n_reads, n_checks, n_errors);
    if (n_errors == 0) $display(" TEST PASSED");
    else               $display(" TEST FAILED");
    $display("==================================================");
    $finish;
  end

  // watchdog
  initial begin
    #50ms;
    $display("ERROR: TIMEOUT");
    $finish;
  end
endmodule
