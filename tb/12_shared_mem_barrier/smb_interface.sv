interface smb_interface (input logic clk, input logic rst_n);
  // shared memory
  logic        req_valid, req_ready, req_we;
  logic [7:0]  req_mask;
  logic [31:0] req_addr [8];
  logic [31:0] req_wdata [8];
  logic [1:0]  req_warp;
  logic [3:0]  req_rd;
  logic        rsp_valid, rsp_we;
  logic [1:0]  rsp_warp;
  logic [3:0]  rsp_rd;
  logic [7:0]  rsp_mask;
  logic [31:0] rsp_data [8];
  logic [3:0]  last_passes;
  // barrier
  logic [3:0]  wl_mask, live, release_mask, waiting;
  logic        arrive_valid;
  logic [1:0]  arrive_warp;
endinterface
