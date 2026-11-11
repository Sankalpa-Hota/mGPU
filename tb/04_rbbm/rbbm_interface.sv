interface rbbm_interface (input logic clk, input logic rst_n);
  logic        psel, penable, pwrite, pready, pslverr;
  logic [11:0] paddr;
  logic [31:0] pwdata, prdata;
  logic [31:0] ring_base;
  logic [9:0]  ring_wptr, ring_rptr;
  logic        ev_fence, ev_bad_pkt, ev_bad_op, progress;
  logic [7:0]  busy_in;
  logic [15:0] perf_ev;
  logic        irq, soft_reset;
endinterface
