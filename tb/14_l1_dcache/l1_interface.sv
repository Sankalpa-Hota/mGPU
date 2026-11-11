interface l1_interface (input logic clk, input logic rst_n);
  logic         req_valid, req_ready, req_we, rsp_valid, invalidate;
  logic [31:0]  req_addr, req_wstrb;
  logic [255:0] req_wdata, rsp_data;
  logic         mreq_valid, mreq_ready, mreq_we, mrsp_valid, last_hit;
  logic [31:0]  mreq_addr, mreq_wstrb;
  logic [255:0] mreq_wdata, mrsp_data;
endinterface
