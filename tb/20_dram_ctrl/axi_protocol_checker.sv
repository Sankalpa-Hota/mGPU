// AXI4 protocol rules (single ID, 32-bit data), usable on any AXI port of mGPU.
module axi_protocol_checker (
  input logic clk, rst_n,
  input logic [31:0] araddr, awaddr, rdata, wdata,
  input logic [7:0] arlen, awlen,
  input logic [2:0] arsize, awsize,
  input logic [1:0] arburst, awburst, rresp, bresp,
  input logic arvalid, arready, rvalid, rready, rlast, awvalid, awready, wvalid, wready, wlast, bvalid, bready,
  input logic [3:0] wstrb
);
  import uvm_pkg::*;
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);
  // every channel: once VALID is high, it stays high with the same payload until READY
  a_ar_stable: assert property ((arvalid && !arready) |=> (arvalid && $stable(araddr) && $stable(arlen) && $stable(arsize) && $stable(arburst)))
    else uvm_report_error("AXI", "AR changed or dropped before ARREADY");
  a_aw_stable: assert property ((awvalid && !awready) |=> (awvalid && $stable(awaddr) && $stable(awlen) && $stable(awsize) && $stable(awburst)))
    else uvm_report_error("AXI", "AW changed or dropped before AWREADY");
  a_w_stable: assert property ((wvalid && !wready) |=> (wvalid && $stable(wdata) && $stable(wstrb) && $stable(wlast)))
    else uvm_report_error("AXI", "W changed or dropped before WREADY");
  a_r_stable: assert property ((rvalid && !rready) |=> (rvalid && $stable(rdata) && $stable(rresp) && $stable(rlast)))
    else uvm_report_error("AXI", "R changed or dropped before RREADY");
  a_b_stable: assert property ((bvalid && !bready) |=> (bvalid && $stable(bresp)))
    else uvm_report_error("AXI", "B changed or dropped before BREADY");
  // a burst never crosses a 4 KB boundary
  a_ar_4k: assert property (arvalid |-> ((araddr & 32'hFFF) + ((arlen + 1) << arsize) <= 32'h1000))
    else uvm_report_error("AXI", "read burst crosses a 4 KB boundary");
  a_aw_4k: assert property (awvalid |-> ((awaddr & 32'hFFF) + ((awlen + 1) << awsize) <= 32'h1000))
    else uvm_report_error("AXI", "write burst crosses a 4 KB boundary");
  // WLAST on exactly the last beat of the burst
  int wbeats, awq_len[$];
  int rbeats, arq_len[$];
  // note: a declaration with an initializer inside a static always block runs only once (time 0),
  // so the expected length is a separate variable assigned on every beat
  int expect_len;
  always_ff @(posedge clk) if (rst_n) begin
    if (awvalid && awready) awq_len.push_back(awlen);
    if (arvalid && arready) arq_len.push_back(arlen);
    if (wvalid && wready) begin
      expect_len = (awq_len.size() != 0) ? awq_len[0] : 7;
      if (wlast !== (wbeats == expect_len)) uvm_report_error("AXI", $sformatf("WLAST=%b on beat %0d of a %0d-beat burst", wlast, wbeats, expect_len + 1));
      if (wlast) begin wbeats <= 0; if (awq_len.size() != 0) void'(awq_len.pop_front()); end else wbeats <= wbeats + 1;
    end
    if (rvalid && rready) begin
      expect_len = (arq_len.size() != 0) ? arq_len[0] : 0;
      if (rlast !== (rbeats == expect_len)) uvm_report_error("AXI", $sformatf("RLAST=%b on beat %0d of a %0d-beat burst", rlast, rbeats, expect_len + 1));
      if (rlast) begin rbeats <= 0; if (arq_len.size() != 0) void'(arq_len.pop_front()); end else rbeats <= rbeats + 1;
    end
  end
  a_no_x: assert property (!$isunknown({arvalid, awvalid, wvalid, rready, bready}))
    else uvm_report_error("AXI", "X on master control signals");
endmodule
