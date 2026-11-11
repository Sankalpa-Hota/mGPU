interface simt_interface (input logic clk, input logic rst_n);
  logic [3:0]  wl_mask, adv_mask, live, ctrl_done, warp_exit;
  logic [31:0] wl_pc;
  logic        br_valid;
  logic [1:0]  br_warp;
  logic [31:0] br_instr, br_pc;
  logic [7:0]  br_taken;
  logic [31:0] pc [4];
  logic [7:0]  mask [4];
  logic        overflow;
  logic [2:0]  depth [4];
endinterface
