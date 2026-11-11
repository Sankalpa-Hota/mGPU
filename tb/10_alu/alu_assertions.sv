module alu_assertions (
  input logic clk, rst_n, wb_valid, wb_ready, br_valid, ex_valid, ex_ready,
  input logic [31:0] wb_d0, ex_instr
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_wb_hold: assert property ((wb_valid && !wb_ready) |=> (wb_valid && $stable(wb_d0)))
    else uvm_report_error("SVA", "writeback changed before the register file took it");
  a_br_pulse: assert property (br_valid |=> !br_valid || $past(ex_valid && ex_ready))
    else uvm_report_error("SVA", "branch result repeated without a new branch");
  a_in_hold: assert property ((ex_valid && !ex_ready) |=> (ex_valid && $stable(ex_instr)))
    else uvm_report_error("SVA", "input changed while stalled (driver)");
endmodule
