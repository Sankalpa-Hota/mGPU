module tb_top;
  import uvm_pkg::*;
  import gbif_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  gbif_interface vif (clk, rst_n);
  gbif dut (.clk(clk), .rst_n(rst_n), .req_valid(vif.req_valid), .req_ready(vif.req_ready), .req_addr(vif.req_addr), .req_we(vif.req_we),
    .req_wdata(vif.req_wdata), .req_wstrb(vif.req_wstrb), .rsp_valid(vif.rsp_valid), .rsp_data(vif.rsp_data), .rsp_err(vif.rsp_err),
    .araddr(vif.araddr), .arlen(vif.arlen), .arsize(vif.arsize), .arburst(vif.arburst), .arvalid(vif.arvalid), .arready(vif.arready),
    .rdata(vif.rdata), .rresp(vif.rresp), .rlast(vif.rlast), .rvalid(vif.rvalid), .rready(vif.rready),
    .awaddr(vif.awaddr), .awlen(vif.awlen), .awsize(vif.awsize), .awburst(vif.awburst), .awvalid(vif.awvalid), .awready(vif.awready),
    .wdata(vif.wdata), .wstrb(vif.wstrb), .wlast(vif.wlast), .wvalid(vif.wvalid), .wready(vif.wready),
    .bresp(vif.bresp), .bvalid(vif.bvalid), .bready(vif.bready));
  axi_protocol_checker u_axi (.clk(clk), .rst_n(rst_n), .araddr(vif.araddr), .awaddr(vif.awaddr), .rdata(vif.rdata), .wdata(vif.wdata),
    .arlen(vif.arlen), .awlen(vif.awlen), .arsize(vif.arsize), .awsize(vif.awsize), .arburst(vif.arburst), .awburst(vif.awburst),
    .rresp(vif.rresp), .bresp(vif.bresp), .arvalid(vif.arvalid), .arready(vif.arready), .rvalid(vif.rvalid), .rready(vif.rready),
    .rlast(vif.rlast), .awvalid(vif.awvalid), .awready(vif.awready), .wvalid(vif.wvalid), .wready(vif.wready), .wlast(vif.wlast),
    .bvalid(vif.bvalid), .bready(vif.bready), .wstrb(vif.wstrb));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | req_v r we addr     | st | ARv r | Rv r last resp beat | AWv r | Wv r last strb | Bv r resp | rsp_v err");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b  %b %h | %0d  |  %b  %b | %b  %b  %b   %0d   %0d  |  %b  %b | %b  %b  %b   %h  | %b  %b  %0d  |  %b    %b",
                  cyc, vif.req_valid, vif.req_ready, vif.req_we, vif.req_addr, dut.state, vif.arvalid, vif.arready, vif.rvalid,
                  vif.rready, vif.rlast, vif.rresp, dut.beat, vif.awvalid, vif.awready, vif.wvalid, vif.wready, vif.wlast, vif.wstrb,
                  vif.bvalid, vif.bready, vif.bresp, vif.rsp_valid, vif.rsp_err);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(gbif_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
