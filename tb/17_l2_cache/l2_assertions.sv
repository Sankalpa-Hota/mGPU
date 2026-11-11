module l2_assertions (input logic clk, rst_n, mreq_valid, mreq_ready, rsp_valid, req_valid, req_ready, flush_req,
                      input logic [31:0] mreq_addr);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_req_hold: assert property ((mreq_valid && !mreq_ready) |=> (mreq_valid && $stable(mreq_addr)))
    else uvm_report_error("SVA", "memory request changed before accepted");
  a_rsp_pulse: assert property (rsp_valid |=> !rsp_valid)
    else uvm_report_error("SVA", "answer longer than one cycle");
  a_no_accept_in_flush: assert property (flush_req |-> !req_ready)
    else uvm_report_error("SVA", "request accepted while a flush is requested");
  a_own_bank: assert property (mreq_valid |-> mreq_addr[5] == 1'b1)
    else uvm_report_error("SVA", "bank 1 issued a memory request for a bank 0 address");
endmodule
