interface icache_interface (input logic clk, input logic rst_n);
  logic [1:0]   req_valid, req_ready, rsp_valid;
  logic [31:0]  req_pc [2];
  logic [31:0]  rsp_instr;
  logic         invalidate;
  logic         mreq_valid, mreq_ready, mrsp_valid;
  logic [31:0]  mreq_addr;
  logic [255:0] mrsp_data;
endinterface
