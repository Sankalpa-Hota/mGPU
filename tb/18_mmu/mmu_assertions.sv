module mmu_assertions (input logic clk, rst_n, mreq_valid, mreq_ready, rsp_valid, rsp_err, fault_valid, fault_clear,
                       input logic [31:0] mreq_addr, input logic [255:0] rsp_data);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_req_hold: assert property ((mreq_valid && !mreq_ready) |=> (mreq_valid && $stable(mreq_addr)))
    else uvm_report_error("SVA", "memory request changed before accepted");
  a_err_zero_data: assert property ((rsp_valid && rsp_err) |-> rsp_data == '0)
    else uvm_report_error("SVA", "fault answer carries data");
  a_fault_sticky: assert property ((fault_valid && !fault_clear) |=> fault_valid)
    else uvm_report_error("SVA", "fault status dropped without clear");
endmodule
