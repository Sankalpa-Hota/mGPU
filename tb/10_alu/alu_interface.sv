interface alu_interface (input logic clk, input logic rst_n);
  logic        ex_valid, ex_ready;
  logic [1:0]  ex_warp;
  logic [31:0] ex_instr, ex_pc;
  logic [7:0]  ex_mask;
  logic [31:0] ex_a [8];
  logic [31:0] ex_b [8];
  logic [31:0] ctx_wg_id, ctx_arg;
  logic [2:0]  ctx_nwarps;
  logic        wb_valid, wb_ready;
  logic [1:0]  wb_warp;
  logic [3:0]  wb_rd;
  logic [7:0]  wb_mask;
  logic [31:0] wb_data [8];
  logic        br_valid;
  logic [1:0]  br_warp;
  logic [31:0] br_instr, br_pc;
  logic [7:0]  br_taken;
endinterface
