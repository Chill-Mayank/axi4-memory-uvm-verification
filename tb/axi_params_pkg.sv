// =============================================================================
// axi_params_pkg.sv : bus sizes + AXI reference functions shared by the
// interface, the UVM package and the top. Change the sizes here only.
// =============================================================================
package axi_params_pkg;
  localparam int DATA_W   = 32;
  localparam int ADDR_W   = 8;
  localparam int ID_W     = 4;
  localparam int NB       = DATA_W / 8;        // bytes per beat on the bus
  localparam int MEMSZ    = 1 << ADDR_W;       // memory size in bytes
  localparam int MAX_SIZE = $clog2(NB);        // largest legal AxSIZE

  localparam bit [1:0] FIXED = 2'b00, INCR = 2'b01, WRAP = 2'b10, RSVD = 2'b11;
  localparam bit [1:0] OKAY  = 2'b00, SLVERR = 2'b10;

  // ---- Reference AXI math, written straight from the spec (beat by beat) ----

  // Address of beat number 'beat' of a burst
  function automatic int beat_addr(int start, int size, int len, int burst, int beat);
    int a     = start;
    int bytes = 1 << size;
    for (int i = 0; i < beat; i++) begin
      if (burst == FIXED) a = a;
      else if (burst == WRAP) begin
        int total = (len + 1) * bytes;
        int lower = (a / total) * total;
        a = (a / bytes) * bytes + bytes;
        if (a >= lower + total) a = lower;
      end
      else a = (a / bytes) * bytes + bytes;
    end
    return a % MEMSZ;
  endfunction

  // Byte lanes of the data bus that are used by beat number 'beat'
  function automatic bit [NB-1:0] beat_lanes(int start, int size, int len, int burst, int beat);
    int a     = beat_addr(start, size, len, burst, beat);
    int bytes = 1 << size;
    int lo    = a % NB;
    int hi    = ((a / bytes) * bytes) % NB + bytes - 1;
    bit [NB-1:0] m = '0;
    if (bytes > NB) return '1;
    for (int b = lo; b <= hi; b++) m[b] = 1'b1;
    return m;
  endfunction

  // Requests this slave answers with SLVERR
  function automatic bit is_illegal(int start, int size, int len, int burst);
    if (burst == RSVD) return 1;
    if (size > MAX_SIZE) return 1;
    if (burst == WRAP && !(len == 1 || len == 3 || len == 7 || len == 15)) return 1;
    if (burst == WRAP && (start % (1 << size)) != 0) return 1;
    return 0;
  endfunction
endpackage
