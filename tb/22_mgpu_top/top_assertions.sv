// System-level properties checked at the boundaries of the main blocks.
module top_assertions (input logic clk, rst_n, input logic [1:0] sm_busy, sm_power, input logic sm0_ovf, sm1_ovf,
                       input logic bad_pkt, bad_op);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_sm_powered_when_busy: assert property ((sm_busy & ~sm_power) == 0)
    else uvm_report_error("SVA", "an SM runs work while the GMU has it powered off");
  a_no_simt_overflow: assert property (!sm0_ovf && !sm1_ovf)
    else uvm_report_error("SVA", "SIMT stack overflow in an SM");
  a_no_bad_commands: assert property (!bad_pkt && !bad_op)
    else uvm_report_error("SVA", "the CP saw an illegal packet or opcode (driver and GPU disagree on the format)");
endmodule
