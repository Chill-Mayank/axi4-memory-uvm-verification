// =============================================================================
// axi_mem.sv : AXI4 memory slave (synthesizable)
//
// Features
//   * All five AXI4 channels with VALID/READY handshakes
//   * Burst types FIXED, INCR and WRAP; burst length 1..256 beats (AxLEN 0..255)
//   * Narrow transfers (AxSIZE smaller than the bus) and unaligned INCR/FIXED start
//   * Byte-lane write strobes (WSTRB)
//   * Transaction IDs returned on B and R (BID = AWID, RID = ARID)
//   * SLVERR response for unsupported requests:
//       - reserved burst type (AxBURST = 2'b11)
//       - AxSIZE larger than the data bus
//       - WRAP burst whose length is not 2, 4, 8 or 16 beats
//       - WRAP burst whose start address is not aligned to AxSIZE
//     Writes with SLVERR do not modify memory; reads with SLVERR return zero.
//   * Read and write paths are independent and can run at the same time.
//     One outstanding transaction per direction.
//
// Memory: byte addressed, MEM_BYTES = 2**ADDR_W bytes.
// Data bus byte lane i carries the byte at (address aligned to the bus) + i.
// =============================================================================
module axi_mem #(
  parameter int DATA_W = 32,            // data bus width in bits (8, 16, 32, 64 ...)
  parameter int ADDR_W = 8,             // byte address width
  parameter int ID_W   = 4              // transaction ID width
)(
  input  logic                clk,
  input  logic                rst_n,

  // ---------------- Write address channel ----------------
  input  logic [ID_W-1:0]     awid,
  input  logic [ADDR_W-1:0]   awaddr,
  input  logic [7:0]          awlen,
  input  logic [2:0]          awsize,
  input  logic [1:0]          awburst,
  input  logic                awvalid,
  output logic                awready,

  // ---------------- Write data channel ----------------
  input  logic [DATA_W-1:0]   wdata,
  input  logic [DATA_W/8-1:0] wstrb,
  input  logic                wlast,
  input  logic                wvalid,
  output logic                wready,

  // ---------------- Write response channel ----------------
  output logic [ID_W-1:0]     bid,
  output logic [1:0]          bresp,
  output logic                bvalid,
  input  logic                bready,

  // ---------------- Read address channel ----------------
  input  logic [ID_W-1:0]     arid,
  input  logic [ADDR_W-1:0]   araddr,
  input  logic [7:0]          arlen,
  input  logic [2:0]          arsize,
  input  logic [1:0]          arburst,
  input  logic                arvalid,
  output logic                arready,

  // ---------------- Read data channel ----------------
  output logic [ID_W-1:0]     rid,
  output logic [DATA_W-1:0]   rdata,
  output logic [1:0]          rresp,
  output logic                rlast,
  output logic                rvalid,
  input  logic                rready
);

  localparam int NB        = DATA_W / 8;          // bytes per bus beat
  localparam int MEM_BYTES = 1 << ADDR_W;
  localparam int MAX_SIZE  = $clog2(NB);          // largest legal AxSIZE

  localparam logic [1:0] BURST_FIXED = 2'b00;
  localparam logic [1:0] BURST_INCR  = 2'b01;
  localparam logic [1:0] BURST_WRAP  = 2'b10;
  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  // Byte-addressed storage
  logic [7:0] mem [0:MEM_BYTES-1];

  // ---------------------------------------------------------------------------
  // Helper functions
  // ---------------------------------------------------------------------------

  // Address of the next beat in a burst (AXI4 spec, section A3.4.1)
  function automatic logic [ADDR_W-1:0] next_addr(
      input logic [ADDR_W-1:0] addr,
      input logic [2:0]        size,
      input logic [7:0]        len,
      input logic [1:0]        burst);
    logic [ADDR_W:0] bytes;      // bytes per beat
    logic [ADDR_W:0] aligned;    // current address aligned to the beat size
    logic [ADDR_W:0] incr;       // aligned + bytes
    logic [ADDR_W+8:0] total;    // total bytes of a wrap burst
    logic [ADDR_W+8:0] lower;    // wrap boundary (lower)
    bytes   = (ADDR_W+1)'(1) << size;
    aligned = {1'b0, addr} & ~(bytes - 1);
    incr    = aligned + bytes;
    case (burst)
      BURST_FIXED: next_addr = addr;
      BURST_WRAP: begin
        total = ((ADDR_W+9)'(len) + 1) << size;
        lower = (ADDR_W+9)'(addr) & ~(total - 1);
        if ((ADDR_W+9)'(incr) >= lower + total) next_addr = lower[ADDR_W-1:0];
        else                                    next_addr = incr[ADDR_W-1:0];
      end
      BURST_INCR: next_addr = incr[ADDR_W-1:0];
      default:    next_addr = incr[ADDR_W-1:0];   // reserved: treated as INCR (request gets SLVERR)
    endcase
  endfunction

  // Is this request something the slave cannot perform?
  function automatic logic is_illegal(
      input logic [ADDR_W-1:0] addr,
      input logic [2:0]        size,
      input logic [7:0]        len,
      input logic [1:0]        burst);
    logic [ADDR_W:0] bytes;
    bytes = (ADDR_W+1)'(1) << size;
    is_illegal = 1'b0;
    if (burst == 2'b11)       is_illegal = 1'b1;
    if (size > 3'(MAX_SIZE))   is_illegal = 1'b1;
    if (burst == BURST_WRAP) begin
      if (!(len == 8'd1 || len == 8'd3 || len == 8'd7 || len == 8'd15)) is_illegal = 1'b1;
      if (({1'b0, addr} & (bytes - 1)) != '0)                          is_illegal = 1'b1;
    end
  endfunction

  // Full bus word that contains the byte at 'addr'
  function automatic logic [DATA_W-1:0] read_word(input logic [ADDR_W-1:0] addr);
    logic [ADDR_W-1:0] base;
    base = addr & ~ADDR_W'(NB - 1);
    for (int b = 0; b < NB; b++)
      read_word[8*b +: 8] = mem[base + ADDR_W'(b)];
  endfunction

  // ===========================================================================
  // WRITE PATH :  W_IDLE --AW--> W_DATA --WLAST--> W_RESP --B--> W_IDLE
  // ===========================================================================
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t           wstate;
  logic [ADDR_W-1:0] w_addr;     // address of the current beat
  logic [7:0]        w_len;
  logic [2:0]        w_size;
  logic [1:0]        w_burst;
  logic [7:0]        w_cnt;      // beats received so far
  logic              w_err;      // request is illegal -> no writes, SLVERR

  assign awready = (wstate == W_IDLE);
  assign wready  = (wstate == W_DATA);
  assign bvalid  = (wstate == W_RESP);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wstate  <= W_IDLE;
      w_addr  <= '0;
      w_len   <= '0;
      w_size  <= '0;
      w_burst <= '0;
      w_cnt   <= '0;
      w_err   <= 1'b0;
      bid     <= '0;
      bresp   <= RESP_OKAY;
    end
    else begin
      case (wstate)
        W_IDLE: if (awvalid) begin                  // awready is 1 in this state
          w_addr  <= awaddr;
          w_len   <= awlen;
          w_size  <= awsize;
          w_burst <= awburst;
          w_cnt   <= '0;
          w_err   <= is_illegal(awaddr, awsize, awlen, awburst);
          bid     <= awid;
          wstate  <= W_DATA;
        end

        W_DATA: if (wvalid) begin                   // wready is 1 in this state
          w_addr <= next_addr(w_addr, w_size, w_len, w_burst);
          w_cnt  <= w_cnt + 8'd1;
          if (wlast) begin
            // SLVERR also if WLAST does not arrive on the beat AWLEN promised
            bresp  <= (w_err || (w_cnt != w_len)) ? RESP_SLVERR : RESP_OKAY;
            wstate <= W_RESP;
          end
        end

        W_RESP: if (bready) wstate <= W_IDLE;

        default: wstate <= W_IDLE;
      endcase
    end
  end

  // Memory write: one byte per enabled strobe lane (no reset on the storage)
  logic [ADDR_W-1:0] w_base;
  assign w_base = w_addr & ~ADDR_W'(NB - 1);

  always_ff @(posedge clk) begin
    if (wstate == W_DATA && wvalid && !w_err) begin
      for (int b = 0; b < NB; b++)
        if (wstrb[b]) mem[w_base + ADDR_W'(b)] <= wdata[8*b +: 8];
    end
  end

  // ===========================================================================
  // READ PATH :  R_IDLE --AR--> R_DATA (one beat per R handshake) --RLAST--> R_IDLE
  // ===========================================================================
  typedef enum logic {R_IDLE, R_DATA} rstate_t;
  rstate_t           rstate;
  logic [ADDR_W-1:0] r_addr;
  logic [7:0]        r_len;
  logic [2:0]        r_size;
  logic [1:0]        r_burst;
  logic [7:0]        r_cnt;
  logic              r_err;
  logic [ADDR_W-1:0] r_next;

  assign arready = (rstate == R_IDLE);
  assign rvalid  = (rstate == R_DATA);
  assign rlast   = (rstate == R_DATA) && (r_cnt == r_len);
  assign r_next  = next_addr(r_addr, r_size, r_len, r_burst);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate  <= R_IDLE;
      r_addr  <= '0;
      r_len   <= '0;
      r_size  <= '0;
      r_burst <= '0;
      r_cnt   <= '0;
      r_err   <= 1'b0;
      rid     <= '0;
      rresp   <= RESP_OKAY;
      rdata   <= '0;
    end
    else begin
      case (rstate)
        R_IDLE: if (arvalid) begin                  // arready is 1 in this state
          r_addr  <= araddr;
          r_len   <= arlen;
          r_size  <= arsize;
          r_burst <= arburst;
          r_cnt   <= '0;
          r_err   <= is_illegal(araddr, arsize, arlen, arburst);
          rid     <= arid;
          rresp   <= is_illegal(araddr, arsize, arlen, arburst) ? RESP_SLVERR : RESP_OKAY;
          rdata   <= is_illegal(araddr, arsize, arlen, arburst) ? '0 : read_word(araddr);
          rstate  <= R_DATA;
        end

        R_DATA: if (rready) begin                   // rvalid is 1 in this state
          if (r_cnt == r_len) begin
            rstate <= R_IDLE;
          end
          else begin
            r_addr <= r_next;
            r_cnt  <= r_cnt + 8'd1;
            rdata  <= r_err ? '0 : read_word(r_next);
          end
        end

        default: rstate <= R_IDLE;
      endcase
    end
  end

endmodule
