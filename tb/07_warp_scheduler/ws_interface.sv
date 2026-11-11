interface ws_interface (input logic clk, input logic rst_n);
  logic [3:0]  wl_mask, live, adv_mask, ctrl_done, elig;
  logic [31:0] pc [4];
  logic        f_valid, f_ready, f_rsp_valid;
  logic [31:0] f_pc, f_rsp_instr;
  logic        is_valid, is_ready;
  logic [1:0]  is_warp;
  logic [31:0] is_instr, is_pc;
  logic [2:0]  wb_valid;
  logic [1:0]  wb_warp [3];
  logic [3:0]  wb_rd [3];
  logic        idle;
endinterface
