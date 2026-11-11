interface dispatcher_interface (input logic clk, input logic rst_n);
  logic        reg_wr_en;
  logic [17:0] reg_wr_addr;
  logic [31:0] reg_wr_data;
  logic        disp_valid, disp_ready;
  logic [31:0] disp_num_wg;
  logic        launch_valid;
  logic [1:0]  launch_slot;
  logic [31:0] launch_wg_id, launch_pc, launch_arg;
  logic [2:0]  launch_nwarps;
  logic [3:0]  wg_done;
  logic [1:0]  sm_avail, sm_want;
  logic        busy;
endinterface
