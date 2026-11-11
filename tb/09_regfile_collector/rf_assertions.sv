module rf_assertions (
  input logic clk, rst_n,
  input logic is_valid, is_ready, ex_valid,
  input logic [3:0] ex_ready,
  input logic [1:0] ex_unit,
  input logic [31:0] ex_instr,
  input logic rd_a, rd_b,
  input logic [1:0] bank_a, bank_b
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  // one read port per bank: never two reads from the same bank in one cycle
  a_one_read_per_bank: assert property (!(rd_a && rd_b && bank_a == bank_b))
    else uvm_report_error("SVA", "two operand reads from the same bank in one cycle");
  a_ex_hold: assert property ((ex_valid && !ex_ready[ex_unit]) |=> (ex_valid && $stable(ex_instr) && $stable(ex_unit)))
    else uvm_report_error("SVA", "offered instruction changed before the unit took it");
  a_no_x: assert property (!$isunknown({is_ready, ex_valid}))
    else uvm_report_error("SVA", "X on control output");
endmodule
