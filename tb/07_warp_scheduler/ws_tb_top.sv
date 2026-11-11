module tb_top;
  import uvm_pkg::*;
  import ws_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end

  ws_interface vif (clk, rst_n);

  warp_scheduler #(.NW(4), .NWB(3)) dut (
    .clk(clk), .rst_n(rst_n), .wl_mask(vif.wl_mask), .live(vif.live), .pc(vif.pc),
    .f_valid(vif.f_valid), .f_ready(vif.f_ready), .f_pc(vif.f_pc), .f_rsp_valid(vif.f_rsp_valid), .f_rsp_instr(vif.f_rsp_instr),
    .is_valid(vif.is_valid), .is_ready(vif.is_ready), .is_warp(vif.is_warp), .is_instr(vif.is_instr), .is_pc(vif.is_pc),
    .adv_mask(vif.adv_mask), .wb_valid(vif.wb_valid), .wb_warp(vif.wb_warp), .wb_rd(vif.wb_rd),
    .ctrl_done(vif.ctrl_done), .elig(vif.elig), .idle(vif.idle));

  ws_assertions u_chk (.clk(clk), .rst_n(rst_n), .is_valid(vif.is_valid), .is_ready(vif.is_ready), .f_valid(vif.f_valid),
    .f_ready(vif.f_ready), .is_warp(vif.is_warp), .is_instr(vif.is_instr), .is_pc(vif.is_pc), .f_pc(vif.f_pc),
    .adv_mask(vif.adv_mask), .live(vif.live));

  int    wf;
  int    cyc;
  string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | live ibuf elig wait | f_v f_r f_pc     rsp | is_v is_r w is_pc    is_instr | adv  | wb  | pend0 pend1 pend2 pend3");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d | %b %b %b %b |  %b   %b  %h  %b  |  %b    %b  %0d %h %h | %b | %b | %h  %h  %h  %h",
                  cyc, vif.live, dut.ibuf_v, vif.elig, dut.ctrl_wait, vif.f_valid, vif.f_ready, vif.f_pc, vif.f_rsp_valid,
                  vif.is_valid, vif.is_ready, vif.is_warp, vif.is_pc, vif.is_instr, vif.adv_mask, vif.wb_valid,
                  dut.pend[0], dut.pend[1], dut.pend[2], dut.pend[3]);
      end
      $fclose(wf);
    end
  end

  initial begin
    uvm_config_db#(ws_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
