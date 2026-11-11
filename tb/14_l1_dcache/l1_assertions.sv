module l1_assertions (input logic clk, rst_n, mreq_valid, mreq_ready, rsp_valid, req_valid, req_ready,
                      input logic [31:0] mreq_addr);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_req_hold: assert property ((mreq_valid && !mreq_ready) |=> (mreq_valid && $stable(mreq_addr)))
    else uvm_report_error("SVA", "memory request changed before accepted");
  a_rsp_pulse: assert property (rsp_valid |=> !rsp_valid)
    else uvm_report_error("SVA", "answer longer than one cycle");
  a_blocking: assert property ((req_valid && req_ready) |=> !req_ready || rsp_valid)
    else uvm_report_error("SVA", "accepted a second access before answering the first");
endmodule
