module rbbm_assertions (
  input logic clk, rst_n,
  input logic psel, penable, pwrite, pready, pslverr,
  input logic [11:0] paddr,
  input logic [31:0] pwdata, prdata,
  input logic soft_reset
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);

  // APB master rules (checks the testbench driver)
  a_setup_first: assert property ($rose(penable) |-> $past(psel && !penable))
    else uvm_report_error("SVA", "APB access phase without a setup phase");
  a_stable_in_access: assert property ((psel && !penable) |=> (psel && penable && $stable(paddr) && $stable(pwrite) && $stable(pwdata)))
    else uvm_report_error("SVA", "APB address/control/data changed between setup and access");
  a_penable_drops: assert property ((psel && penable && pready) |=> !penable)
    else uvm_report_error("SVA", "penable stayed high after the transfer completed");
  // APB slave rules (checks the DUT)
  a_slverr_only_in_access: assert property (pslverr |-> (psel && penable && pready))
    else uvm_report_error("SVA", "PSLVERR outside the access phase");
  a_rdata_known: assert property ((psel && penable && !pwrite) |-> !$isunknown(prdata))
    else uvm_report_error("SVA", "X on PRDATA during a read");
  a_soft_reset_pulse: assert property (soft_reset |=> !soft_reset)
    else uvm_report_error("SVA", "soft_reset longer than one cycle");
endmodule
