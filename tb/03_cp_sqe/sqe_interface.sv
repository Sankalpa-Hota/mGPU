interface sqe_interface (input logic clk, input logic rst_n);
  logic         op_valid, op_ready, op_last;
  logic [6:0]   op_code;
  logic [31:0]  op_data;
  logic         disp_valid, disp_ready;
  logic [31:0]  disp_num_wg;
  logic [7:0]   busy_in;
  logic         mreq_valid, mreq_ready, mreq_we;
  logic [31:0]  mreq_addr;
  logic [255:0] mreq_wdata;
  logic [31:0]  mreq_wstrb;
  logic         mrsp_valid;
  logic         irq, op_done, bad_op, busy;
endinterface
