module simt_assertions (
  input logic clk, rst_n,
  input logic [3:0] live, ctrl_done, warp_exit, adv_mask,
  input logic br_valid, overflow,
  input logic [7:0] mask0, mask1, mask2, mask3
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  // a live warp always has at least one active lane; a dead warp has none
  a_live_has_lanes: assert property ((live[0] == (mask0 != 0)) && (live[1] == (mask1 != 0)) && (live[2] == (mask2 != 0)) && (live[3] == (mask3 != 0)))
    else uvm_report_error("SVA", "live warp with an empty mask (or dead warp with lanes)");
  a_done_after_branch: assert property (ctrl_done != 0 |-> $past(br_valid) && $onehot(ctrl_done))
    else uvm_report_error("SVA", "ctrl_done without a branch the cycle before");
  a_exit_kills: assert property ((warp_exit & live) == 0)
    else uvm_report_error("SVA", "warp_exit pulse while the warp is still live");
  a_overflow_sticky: assert property (overflow |=> overflow)
    else uvm_report_error("SVA", "overflow flag dropped");
endmodule
