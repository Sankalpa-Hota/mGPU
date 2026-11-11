module tb_top;
  import uvm_pkg::*;
  import dispatcher_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end

  dispatcher_interface vif (clk, rst_n);

  dispatcher #(.NSM(2), .NSUB(2)) dut (
    .clk(clk), .rst_n(rst_n), .reg_wr_en(vif.reg_wr_en), .reg_wr_addr(vif.reg_wr_addr), .reg_wr_data(vif.reg_wr_data),
    .disp_valid(vif.disp_valid), .disp_ready(vif.disp_ready), .disp_num_wg(vif.disp_num_wg),
    .launch_valid(vif.launch_valid), .launch_slot(vif.launch_slot), .launch_wg_id(vif.launch_wg_id),
    .launch_nwarps(vif.launch_nwarps), .launch_pc(vif.launch_pc), .launch_arg(vif.launch_arg),
    .wg_done(vif.wg_done), .sm_avail(vif.sm_avail), .sm_want(vif.sm_want), .busy(vif.busy));

  dispatcher_assertions u_chk (.clk(clk), .rst_n(rst_n), .disp_valid(vif.disp_valid), .disp_ready(vif.disp_ready),
    .launch_valid(vif.launch_valid), .busy(vif.busy), .disp_num_wg(vif.disp_num_wg), .launch_slot(vif.launch_slot),
    .wg_done(vif.wg_done));

  int    wf;
  int    cyc;
  string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | regwr addr  | disp_v disp_r nwg | remain occ  avail | launch slot wg  nw pc       | done | busy want");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |   %b   %h |   %b      %b    %3d |  %3d   %b  %b   |   %b     %0d  %3d %0d  %h | %b |  %b    %b",
                  cyc, vif.reg_wr_en, vif.reg_wr_addr, vif.disp_valid, vif.disp_ready, vif.disp_num_wg,
                  dut.remaining, dut.occ, vif.sm_avail, vif.launch_valid, vif.launch_slot, vif.launch_wg_id,
                  vif.launch_nwarps, vif.launch_pc, vif.wg_done, vif.busy, vif.sm_want);
      end
      $fclose(wf);
    end
  end

  initial begin
    uvm_config_db#(disp_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
