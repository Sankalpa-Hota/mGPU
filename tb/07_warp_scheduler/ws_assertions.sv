module ws_assertions (
  input logic clk, rst_n,
  input logic is_valid, is_ready, f_valid, f_ready,
  input logic [1:0] is_warp,
  input logic [31:0] is_instr, is_pc, f_pc,
  input logic [3:0] adv_mask, live
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  // valid/ready toward the operand collector: an offered instruction is held until taken
  a_issue_hold: assert property ((is_valid && !is_ready) |=> (is_valid && $stable(is_warp) && $stable(is_instr) && $stable(is_pc)))
    else uvm_report_error("SVA", "offered instruction changed or vanished before it was accepted");
  a_fetch_hold: assert property ((f_valid && !f_ready) |=> (f_valid && $stable(f_pc)))
    else uvm_report_error("SVA", "fetch request changed before it was accepted");
  a_adv_only_on_issue: assert property (adv_mask != 0 |-> (is_valid && is_ready && $onehot(adv_mask)))
    else uvm_report_error("SVA", "pc advance without an issue");
  a_no_x: assert property (!$isunknown({is_valid, f_valid, adv_mask}))
    else uvm_report_error("SVA", "X on control output");
endmodule
