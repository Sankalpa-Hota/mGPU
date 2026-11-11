interface l2_interface (input logic clk, input logic rst_n);
  logic         req_valid, req_ready, req_we, rsp_valid, flush_req, flush_done, busy;
  logic [31:0]  req_addr, req_wstrb;
  logic [255:0] req_wdata, rsp_data;
  logic [1:0]   req_id, rsp_id;
  logic         mreq_valid, mreq_ready, mreq_we, mrsp_valid, mrsp_err;
  logic [31:0]  mreq_addr;
  logic [255:0] mreq_wdata, mrsp_data;
endinterface
