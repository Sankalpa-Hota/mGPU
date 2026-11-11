interface dram_interface (input logic clk, input logic rst_n);
  logic [31:0] araddr, rdata, awaddr, wdata;
  logic [7:0]  arlen, awlen;
  logic [2:0]  arsize, awsize;
  logic [1:0]  arburst, awburst, rresp, bresp;
  logic        arvalid, arready, rlast, rvalid, rready, awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  logic [3:0]  wstrb;
  logic        stat_row_hit, stat_row_miss;
endinterface
