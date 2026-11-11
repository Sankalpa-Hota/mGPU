module sfu_assertions (input logic clk, rst_n, ex_valid, ex_ready, wb_valid, wb_ready, busy, input logic [31:0] wb_d0);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_no_accept_when_busy: assert property ((ex_valid && ex_ready) |-> !busy || (wb_valid && wb_ready))
    else uvm_report_error("SVA", "new instruction accepted while busy");
  a_wb_hold: assert property ((wb_valid && !wb_ready) |=> (wb_valid && $stable(wb_d0)))
    else uvm_report_error("SVA", "result changed before it was written");
endmodule
