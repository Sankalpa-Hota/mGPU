module icache_assertions (
  input logic clk, rst_n,
  input logic [1:0] req_valid, req_ready, rsp_valid,
  input logic [31:0] req_pc0, req_pc1,
  input logic mreq_valid, mreq_ready,
  input logic [31:0] mreq_addr
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_one_grant: assert property ($countones(req_ready) <= 1)
    else uvm_report_error("SVA", "two ports granted in the same cycle");
  a_ready_needs_valid: assert property ((req_ready & ~req_valid) == 0)
    else uvm_report_error("SVA", "ready given to a port that is not requesting");
  a_one_answer: assert property ($countones(rsp_valid) <= 1)
    else uvm_report_error("SVA", "two answers in the same cycle");
  a_req0_stable: assert property ((req_valid[0] && !req_ready[0]) |=> (req_valid[0] && $stable(req_pc0)))
    else uvm_report_error("SVA", "port 0 request changed while waiting (driver)");
  a_req1_stable: assert property ((req_valid[1] && !req_ready[1]) |=> (req_valid[1] && $stable(req_pc1)))
    else uvm_report_error("SVA", "port 1 request changed while waiting (driver)");
  a_fill_stable: assert property ((mreq_valid && !mreq_ready) |=> (mreq_valid && $stable(mreq_addr)))
    else uvm_report_error("SVA", "line fill request changed before accepted");
  a_fill_aligned: assert property (mreq_valid |-> mreq_addr[4:0] == 0)
    else uvm_report_error("SVA", "line fill address not aligned");
endmodule
