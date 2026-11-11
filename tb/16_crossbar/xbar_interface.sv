interface xbar_interface (input logic clk, input logic rst_n);
  logic [3:0]   req_valid, req_ready, rsp_valid;
  logic [31:0]  req_addr [4];
  logic         req_we [4];
  logic [255:0] req_wdata [4];
  logic [31:0]  req_wstrb [4];
  logic [255:0] rsp_data [4];
  logic [1:0]   b_valid, b_ready, b_rsp_valid;
  logic [31:0]  b_addr [2];
  logic         b_we [2];
  logic [255:0] b_wdata [2];
  logic [31:0]  b_wstrb [2];
  logic [1:0]   b_id [2];
  logic [255:0] b_rsp_data [2];
  logic [1:0]   b_rsp_id [2];
endinterface
