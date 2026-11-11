interface gbif_interface (input logic clk, input logic rst_n);
  logic         req_valid, req_ready, req_we, rsp_valid, rsp_err;
  logic [31:0]  req_addr, req_wstrb;
  logic [255:0] req_wdata, rsp_data;
  logic [31:0]  araddr, rdata, awaddr, wdata;
  logic [7:0]   arlen, awlen;
  logic [2:0]   arsize, awsize;
  logic [1:0]   arburst, awburst, rresp, bresp;
  logic         arvalid, arready, rlast, rvalid, rready, awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  logic [3:0]   wstrb;
endinterface
