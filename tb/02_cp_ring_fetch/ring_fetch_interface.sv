interface ring_fetch_interface #(parameter int RING_LOG2 = 6) (input logic clk, input logic rst_n);
  logic [31:0]          ring_base;
  logic [RING_LOG2-1:0] wptr;
  logic [RING_LOG2-1:0] rptr;
  logic                 mreq_valid;
  logic                 mreq_ready;
  logic [31:0]          mreq_addr;
  logic                 mrsp_valid;
  logic [255:0]         mrsp_data;
  logic                 dw_valid;
  logic                 dw_ready;
  logic [31:0]          dw_data;
  logic                 busy;
endinterface
