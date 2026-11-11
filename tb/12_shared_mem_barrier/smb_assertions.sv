module smb_assertions (input logic clk, rst_n, req_valid, req_ready, rsp_valid,
                       input logic [3:0] release_mask, waiting, live);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  a_one_access: assert property ((req_valid && req_ready) |=> !req_ready)
    else uvm_report_error("SVA", "shared memory accepted a second access while busy");
  a_rsp_pulse: assert property (rsp_valid |=> !rsp_valid)
    else uvm_report_error("SVA", "response longer than one cycle");
endmodule
