module tb_top;
  import uvm_pkg::*;
  import sm_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  sm_interface vif (clk, rst_n);
  sm dut (.clk(clk), .rst_n(rst_n), .launch_valid(vif.launch_valid), .launch_sub(vif.launch_sub), .launch_wg_id(vif.launch_wg_id),
    .launch_nwarps(vif.launch_nwarps), .launch_pc(vif.launch_pc), .launch_arg(vif.launch_arg), .wg_done(vif.wg_done),
    .busy(vif.busy), .invalidate(vif.invalidate), .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready),
    .mreq_addr(vif.mreq_addr), .mreq_we(vif.mreq_we), .mreq_wdata(vif.mreq_wdata), .mreq_wstrb(vif.mreq_wstrb),
    .mrsp_valid(vif.mrsp_valid), .mrsp_data(vif.mrsp_data), .stat_issue(vif.stat_issue),
    .stat_l1_hit_pulse(vif.stat_l1_hit_pulse), .stat_overflow(vif.stat_overflow));
  sm_assertions u_chk (.clk(clk), .rst_n(rst_n), .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready),
    .mrsp_valid(vif.mrsp_valid), .mreq_we(vif.mreq_we), .mreq_addr(vif.mreq_addr), .wg_done(vif.wg_done));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | launch sub wg | sub0: live mask0    pc0      issue | sub1: live issue | mreq_v r we addr     | mrsp | done");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 400) break;
        $fdisplay(wf, "%5d |   %b    %0d  %2d | %b %b %h  %b   | %b  %b    |   %b    %b  %b %h |  %b   | %b", cyc,
                  vif.launch_valid, vif.launch_sub, vif.launch_wg_id, dut.g_sub[0].u_sub.live, dut.g_sub[0].u_sub.mask[0],
                  dut.g_sub[0].u_sub.pc[0], vif.stat_issue[0], dut.g_sub[1].u_sub.live, vif.stat_issue[1],
                  vif.mreq_valid, vif.mreq_ready, vif.mreq_we, vif.mreq_addr, vif.mrsp_valid, vif.wg_done);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(sm_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
