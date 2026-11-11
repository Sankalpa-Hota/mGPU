module gmu_assertions (input logic clk, rst_n, input logic [1:0] sm_busy, sm_power, sm_avail);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_never_off_busy: assert property ((sm_busy & ~sm_power) == 0)
    else uvm_report_error("SVA", "an SM is busy while its power is off");
  a_avail_needs_power: assert property ((sm_avail & ~sm_power) == 0)
    else uvm_report_error("SVA", "an SM is offered to the dispatcher while powered off");
endmodule
