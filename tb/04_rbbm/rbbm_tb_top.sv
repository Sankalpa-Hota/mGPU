module tb_top;
  import uvm_pkg::*;
  import rbbm_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end

  rbbm_interface vif (clk, rst_n);

  rbbm #(.RING_LOG2(10), .NBUSY(8), .NEV(16)) dut (
    .clk(clk), .rst_n(rst_n),
    .psel(vif.psel), .penable(vif.penable), .pwrite(vif.pwrite), .paddr(vif.paddr), .pwdata(vif.pwdata),
    .prdata(vif.prdata), .pready(vif.pready), .pslverr(vif.pslverr),
    .ring_base(vif.ring_base), .ring_wptr(vif.ring_wptr), .ring_rptr(vif.ring_rptr),
    .ev_fence(vif.ev_fence), .ev_bad_pkt(vif.ev_bad_pkt), .ev_bad_op(vif.ev_bad_op), .busy_in(vif.busy_in),
    .progress(vif.progress), .perf_ev(vif.perf_ev), .irq(vif.irq), .soft_reset(vif.soft_reset));

  rbbm_assertions u_chk (
    .clk(clk), .rst_n(rst_n), .psel(vif.psel), .penable(vif.penable), .pwrite(vif.pwrite), .pready(vif.pready),
    .pslverr(vif.pslverr), .paddr(vif.paddr), .pwdata(vif.pwdata), .prdata(vif.prdata), .soft_reset(vif.soft_reset));

  int    wf;
  int    cyc;
  string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | psel pen wr addr wdata    rdata    err | fence bpkt bop busy prog | status mask hang_cnt | irq");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b   %b  %h %h %h  %b  |   %b     %b    %b   %h   %b   |   %h     %h   %4d     |  %b",
                  cyc, vif.psel, vif.penable, vif.pwrite, vif.paddr, vif.pwdata, vif.prdata, vif.pslverr,
                  vif.ev_fence, vif.ev_bad_pkt, vif.ev_bad_op, vif.busy_in, vif.progress,
                  dut.irq_status, dut.irq_mask, dut.hang_cnt, vif.irq);
      end
      $fclose(wf);
    end
  end

  initial begin
    uvm_config_db#(rbbm_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
