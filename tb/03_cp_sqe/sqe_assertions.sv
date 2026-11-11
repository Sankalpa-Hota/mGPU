module sqe_assertions (
  input logic clk, rst_n,
  input logic op_valid, op_ready, op_last,
  input logic [6:0] op_code,
  input logic [31:0] op_data,
  input logic disp_valid, disp_ready,
  input logic [31:0] disp_num_wg,
  input logic mreq_valid, mreq_ready,
  input logic [31:0] mreq_addr, mreq_wstrb,
  input logic irq, op_done, bad_op, busy
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);

  // One operation at a time: after the last payload dword the SQE refuses input until op_done.
  a_hold_input: assert property ((op_valid && op_ready && op_last) |=> !op_ready)
    else uvm_report_error("SVA", "op_ready high while an operation executes");
  a_disp_stable: assert property ((disp_valid && !disp_ready) |=> (disp_valid && $stable(disp_num_wg)))
    else uvm_report_error("SVA", "dispatch request dropped or changed before accepted");
  a_req_stable: assert property ((mreq_valid && !mreq_ready) |=> (mreq_valid && $stable(mreq_addr) && $stable(mreq_wstrb)))
    else uvm_report_error("SVA", "memory write dropped or changed before accepted");
  a_one_request: assert property (!(disp_valid && mreq_valid))
    else uvm_report_error("SVA", "dispatch and memory write requested together");
  a_irq_pulse: assert property (irq |=> !irq)
    else uvm_report_error("SVA", "IRQ longer than one cycle");
  a_done_pulse: assert property (op_done |=> !op_done)
    else uvm_report_error("SVA", "op_done longer than one cycle");
  a_one_strobe_dword: assert property (mreq_valid |-> ($countones(mreq_wstrb) == 4))
    else uvm_report_error("SVA", "fence write must enable exactly one dword");
  a_bad_sticky: assert property (bad_op |=> bad_op)
    else uvm_report_error("SVA", "bad_op dropped without reset");
  a_in_stable: assert property ((op_valid && !op_ready) |=> (op_valid && $stable(op_data) && $stable(op_code) && $stable(op_last)))
    else uvm_report_error("SVA", "input op dword changed while stalled");
  a_no_x: assert property (!$isunknown({op_ready, disp_valid, mreq_valid, irq, op_done, bad_op, busy}))
    else uvm_report_error("SVA", "X on control output");
endmodule
