module sm_assertions (input logic clk, rst_n, mreq_valid, mreq_ready, mrsp_valid, mreq_we, input logic [31:0] mreq_addr,
                      input logic [1:0] wg_done);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  int outstanding;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) outstanding <= 0; else outstanding <= outstanding + (mreq_valid && mreq_ready) - mrsp_valid;
  a_req_hold: assert property ((mreq_valid && !mreq_ready) |=> (mreq_valid && $stable(mreq_addr) && $stable(mreq_we)))
    else uvm_report_error("SVA", "SM memory request changed before accepted");
  a_one_outstanding: assert property (outstanding <= 1)
    else uvm_report_error("SVA", "more than one SM memory request outstanding");
  a_rsp_needs_req: assert property (mrsp_valid |-> outstanding == 1)
    else uvm_report_error("SVA", "memory response with no request");
  a_aligned: assert property (mreq_valid |-> mreq_addr[4:0] == 0)
    else uvm_report_error("SVA", "unaligned line request");
endmodule
