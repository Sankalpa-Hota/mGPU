module xbar_assertions (input logic clk, rst_n, input logic [1:0] b_valid, b_ready, input logic [31:0] b_addr0, b_addr1,
                        input logic [1:0] b_id0, b_id1, input logic [3:0] req_ready, req_valid);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_b0_hold: assert property ((b_valid[0] && !b_ready[0]) |=> (b_valid[0] && $stable(b_addr0) && $stable(b_id0)))
    else uvm_report_error("SVA", "bank 0 request changed before accepted");
  a_b1_hold: assert property ((b_valid[1] && !b_ready[1]) |=> (b_valid[1] && $stable(b_addr1) && $stable(b_id1)))
    else uvm_report_error("SVA", "bank 1 request changed before accepted");
  a_ready_needs_valid: assert property ((req_ready & ~req_valid) == 0)
    else uvm_report_error("SVA", "ready to a requester that is not requesting");
endmodule
