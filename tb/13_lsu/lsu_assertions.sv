module lsu_assertions (input logic clk, rst_n, mreq_valid, mreq_ready, sm_valid, sm_ready, wb_valid, wb_ready,
                       input logic [31:0] mreq_addr, mreq_wstrb);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_req_hold: assert property ((mreq_valid && !mreq_ready) |=> (mreq_valid && $stable(mreq_addr) && $stable(mreq_wstrb)))
    else uvm_report_error("SVA", "line request changed before it was accepted");
  a_req_aligned: assert property (mreq_valid |-> mreq_addr[4:0] == 0)
    else uvm_report_error("SVA", "line request not aligned");
  a_one_path: assert property (!(mreq_valid && sm_valid))
    else uvm_report_error("SVA", "global and shared requests at the same time");
  a_wb_hold: assert property ((wb_valid && !wb_ready) |=> wb_valid)
    else uvm_report_error("SVA", "writeback dropped before accepted");
endmodule
