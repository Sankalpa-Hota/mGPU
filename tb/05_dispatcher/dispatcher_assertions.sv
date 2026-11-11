module dispatcher_assertions (
  input logic clk, rst_n,
  input logic disp_valid, disp_ready, launch_valid, busy,
  input logic [31:0] disp_num_wg,
  input logic [1:0] launch_slot,
  input logic [3:0] wg_done
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_disp_stable: assert property ((disp_valid && !disp_ready) |=> (disp_valid && $stable(disp_num_wg)))
    else uvm_report_error("SVA", "DISPATCH request changed while waiting (driver)");
  // busy must rise in time for WAIT_FOR_IDLE: at the latest one cycle after a DISPATCH with work
  a_busy_after_dispatch: assert property ((disp_valid && disp_ready && disp_num_wg != 0) |=> busy)
    else uvm_report_error("SVA", "busy not set the cycle after DISPATCH (breaks the SQE settle contract)");
  a_no_launch_idle: assert property (!busy |-> !launch_valid)
    else uvm_report_error("SVA", "launch while not busy");
  a_no_x: assert property (!$isunknown({disp_ready, launch_valid, busy}))
    else uvm_report_error("SVA", "X on control output");
endmodule
