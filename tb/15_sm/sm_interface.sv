interface sm_interface (input logic clk, input logic rst_n);
  logic         launch_valid, launch_sub, invalidate, busy;
  logic [31:0]  launch_wg_id, launch_pc, launch_arg;
  logic [2:0]   launch_nwarps;
  logic [1:0]   wg_done, stat_issue;
  logic         mreq_valid, mreq_ready, mreq_we, mrsp_valid, stat_l1_hit_pulse, stat_overflow;
  logic [31:0]  mreq_addr, mreq_wstrb;
  logic [255:0] mreq_wdata, mrsp_data;
endinterface
