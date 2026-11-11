module ring_fetch_assertions #(parameter int RING_LOG2 = 6, parameter int FIFO_DEPTH = 16) (
  input logic clk, rst_n,
  input logic mreq_valid, mreq_ready, mrsp_valid,
  input logic [31:0] mreq_addr,
  input logic dw_valid, dw_ready,
  input logic [31:0] dw_data,
  input logic [RING_LOG2-1:0] wptr, rptr,
  input logic busy,
  input logic [4:0] fifo_count
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);

  int outstanding;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) outstanding <= 0;
    else outstanding <= outstanding + (mreq_valid && mreq_ready) - mrsp_valid;

  // valid/ready rule on the request: once offered, held with the same address until accepted.
  a_req_stable: assert property ((mreq_valid && !mreq_ready) |=> (mreq_valid && $stable(mreq_addr)))
    else uvm_report_error("SVA", "request dropped or changed before it was accepted");
  a_req_aligned: assert property (mreq_valid |-> (mreq_addr[4:0] == 5'd0))
    else uvm_report_error("SVA", "request address not line aligned");
  // Single outstanding request by design; a second one would break the room reservation.
  a_one_outstanding: assert property (outstanding <= 1 && !(mreq_valid && outstanding == 1))
    else uvm_report_error("SVA", "more than one request outstanding");
  a_fifo_bound: assert property (fifo_count <= FIFO_DEPTH)
    else uvm_report_error("SVA", "FIFO count above depth (overflow)");
  a_out_stable: assert property ((dw_valid && !dw_ready) |=> (dw_valid && $stable(dw_data)))
    else uvm_report_error("SVA", "output dword changed while stalled");
  a_rptr_only_on_pop: assert property ((rptr != $past(rptr)) |-> $past(dw_valid && dw_ready))
    else uvm_report_error("SVA", "RPTR moved without a delivered dword");
  a_idle_means_empty: assert property (!busy |-> (wptr == rptr && !dw_valid))
    else uvm_report_error("SVA", "busy low while work remains");
  a_no_x: assert property (!$isunknown({mreq_valid, dw_valid, busy, rptr}))
    else uvm_report_error("SVA", "X on control output");
endmodule
