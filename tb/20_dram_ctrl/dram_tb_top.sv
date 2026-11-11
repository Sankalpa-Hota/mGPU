module tb_top;
  import uvm_pkg::*;
  import dram_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  dram_interface vif (clk, rst_n);
  dram_ctrl #(.MW(MW), .T_HIT(2), .T_MISS(8)) dut (.clk(clk), .rst_n(rst_n),
    .araddr(vif.araddr), .arlen(vif.arlen), .arsize(vif.arsize), .arburst(vif.arburst), .arvalid(vif.arvalid), .arready(vif.arready),
    .rdata(vif.rdata), .rresp(vif.rresp), .rlast(vif.rlast), .rvalid(vif.rvalid), .rready(vif.rready),
    .awaddr(vif.awaddr), .awlen(vif.awlen), .awsize(vif.awsize), .awburst(vif.awburst), .awvalid(vif.awvalid), .awready(vif.awready),
    .wdata(vif.wdata), .wstrb(vif.wstrb), .wlast(vif.wlast), .wvalid(vif.wvalid), .wready(vif.wready),
    .bresp(vif.bresp), .bvalid(vif.bvalid), .bready(vif.bready), .stat_row_hit(vif.stat_row_hit), .stat_row_miss(vif.stat_row_miss));
  axi_protocol_checker u_axi (.clk(clk), .rst_n(rst_n), .araddr(vif.araddr), .awaddr(vif.awaddr), .rdata(vif.rdata), .wdata(vif.wdata),
    .arlen(vif.arlen), .awlen(vif.awlen), .arsize(vif.arsize), .awsize(vif.awsize), .arburst(vif.arburst), .awburst(vif.awburst),
    .rresp(vif.rresp), .bresp(vif.bresp), .arvalid(vif.arvalid), .arready(vif.arready), .rvalid(vif.rvalid), .rready(vif.rready),
    .rlast(vif.rlast), .awvalid(vif.awvalid), .awready(vif.awready), .wvalid(vif.wvalid), .wready(vif.wready), .wlast(vif.wlast),
    .bvalid(vif.bvalid), .bready(vif.bready), .wstrb(vif.wstrb));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | ARv r addr     len | Rv r last resp data     | AWv r addr     len | Wv r last strb | Bv r resp | hit miss");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b  %b %h %2d | %b  %b  %b    %0d  %h |  %b  %b %h %2d | %b  %b  %b   %h  | %b  %b  %0d  |  %b   %b", cyc,
                  vif.arvalid, vif.arready, vif.araddr, vif.arlen, vif.rvalid, vif.rready, vif.rlast, vif.rresp, vif.rdata,
                  vif.awvalid, vif.awready, vif.awaddr, vif.awlen, vif.wvalid, vif.wready, vif.wlast, vif.wstrb,
                  vif.bvalid, vif.bready, vif.bresp, vif.stat_row_hit, vif.stat_row_miss);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(dram_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
