// Protocol and structural properties checked every cycle, independent of the scoreboard.
module cp_assertions (
  input logic clk, rst_n,
  input logic dw_valid, dw_ready, out_ready, busy,
  input logic [31:0] dw_data,
  input logic reg_wr_en, op_valid, op_last, bad_pkt
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);

  // A cycle is either a register write or an opcode dword, never both.
  a_one_output: assert property (!(reg_wr_en && op_valid))
    else uvm_report_error("SVA", "reg_wr_en and op_valid high together");
  // An output only appears on a cycle where a payload dword is actually transferred.
  a_out_needs_xfer: assert property ((reg_wr_en || op_valid) |-> (dw_valid && dw_ready && out_ready))
    else uvm_report_error("SVA", "output without an accepted dword");
  // Headers are always accepted: the decoder must never stall between packets.
  a_hdr_ready: assert property (!busy |-> dw_ready)
    else uvm_report_error("SVA", "dw_ready low while waiting for a header");
  // During a payload, ready follows the downstream exactly (no extra bubbles, no overrun).
  a_payload_ready: assert property (busy |-> (dw_ready == out_ready))
    else uvm_report_error("SVA", "payload ready does not follow out_ready");
  // The error flag is sticky until reset.
  a_bad_sticky: assert property (bad_pkt |=> bad_pkt)
    else uvm_report_error("SVA", "bad_pkt dropped without reset");
  // op_last only marks an opcode dword.
  a_last_on_op: assert property (op_last |-> op_valid)
    else uvm_report_error("SVA", "op_last without op_valid");
  // Input rule (checks the driver): a stalled dword stays valid and unchanged.
  a_in_stable: assert property ((dw_valid && !dw_ready) |=> (dw_valid && $stable(dw_data)))
    else uvm_report_error("SVA", "input dword changed while stalled");
  // No X on control outputs after reset.
  a_no_x: assert property (!$isunknown({dw_ready, reg_wr_en, op_valid, bad_pkt, busy}))
    else uvm_report_error("SVA", "X on decoder control output");

  c_stall_payload: cover property (busy && dw_valid && !dw_ready);
  c_back_to_back:  cover property (reg_wr_en ##1 op_valid);
endmodule
