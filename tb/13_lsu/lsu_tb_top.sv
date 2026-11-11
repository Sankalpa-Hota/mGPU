module tb_top;
  import uvm_pkg::*;
  import lsu_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  lsu_interface vif (clk, rst_n);
  lsu #(.NW(4)) dut (.clk(clk), .rst_n(rst_n), .ex_valid(vif.ex_valid), .ex_ready(vif.ex_ready), .ex_warp(vif.ex_warp),
    .ex_instr(vif.ex_instr), .ex_mask(vif.ex_mask), .ex_a(vif.ex_a), .ex_b(vif.ex_b),
    .sm_valid(vif.sm_valid), .sm_ready(vif.sm_ready), .sm_we(vif.sm_we), .sm_mask(vif.sm_mask), .sm_addr(vif.sm_addr),
    .sm_wdata(vif.sm_wdata), .sm_rsp_valid(vif.sm_rsp_valid), .sm_rsp_data(vif.sm_rsp_data),
    .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .mreq_addr(vif.mreq_addr), .mreq_we(vif.mreq_we),
    .mreq_wdata(vif.mreq_wdata), .mreq_wstrb(vif.mreq_wstrb), .mrsp_valid(vif.mrsp_valid), .mrsp_data(vif.mrsp_data),
    .wb_valid(vif.wb_valid), .wb_ready(vif.wb_ready), .wb_warp(vif.wb_warp), .wb_rd(vif.wb_rd), .wb_mask(vif.wb_mask),
    .wb_data(vif.wb_data), .busy(vif.busy), .last_lines(vif.last_lines));
  lsu_assertions u_chk (.clk(clk), .rst_n(rst_n), .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .sm_valid(vif.sm_valid),
    .sm_ready(vif.sm_ready), .wb_valid(vif.wb_valid), .wb_ready(vif.wb_ready), .mreq_addr(vif.mreq_addr), .mreq_wstrb(vif.mreq_wstrb));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | ex_v rdy op | st pend     serve    | mreq_v r we addr     wstrb    | mrsp | wb_v r data[0]");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b  %h |  %0d %b %b |   %b    %b  %b %h %h |  %b   |  %b   %b %h", cyc, vif.ex_valid, vif.ex_ready,
                  vif.ex_instr[31:26], dut.state, dut.pend, dut.serve, vif.mreq_valid, vif.mreq_ready, vif.mreq_we, vif.mreq_addr,
                  vif.mreq_wstrb, vif.mrsp_valid, vif.wb_valid, vif.wb_ready, vif.wb_data[0]);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(lsu_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
