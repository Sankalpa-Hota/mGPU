module tb_top;
  import uvm_pkg::*;
  import simt_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end

  simt_interface vif (clk, rst_n);

  simt_stack #(.NW(4), .DEPTH(DEPTH)) dut (
    .clk(clk), .rst_n(rst_n), .wl_mask(vif.wl_mask), .wl_pc(vif.wl_pc), .adv_mask(vif.adv_mask),
    .br_valid(vif.br_valid), .br_warp(vif.br_warp), .br_instr(vif.br_instr), .br_pc(vif.br_pc), .br_taken(vif.br_taken),
    .pc(vif.pc), .mask(vif.mask), .live(vif.live), .ctrl_done(vif.ctrl_done), .warp_exit(vif.warp_exit),
    .overflow(vif.overflow), .depth(vif.depth));

  simt_assertions u_chk (.clk(clk), .rst_n(rst_n), .live(vif.live), .ctrl_done(vif.ctrl_done), .warp_exit(vif.warp_exit),
    .adv_mask(vif.adv_mask), .br_valid(vif.br_valid), .overflow(vif.overflow),
    .mask0(vif.mask[0]), .mask1(vif.mask[1]), .mask2(vif.mask[2]), .mask3(vif.mask[3]));

  int    wf;
  int    cyc;
  string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | adv  br w instr    taken    | pc0      mask0    d0 | pc1      mask1    d1 | live done exit");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d | %b %b %0d %h %b | %h %b %0d | %h %b %0d | %b %b %b",
                  cyc, vif.adv_mask, vif.br_valid, vif.br_warp, vif.br_instr, vif.br_taken,
                  vif.pc[0], vif.mask[0], vif.depth[0], vif.pc[1], vif.mask[1], vif.depth[1], vif.live, vif.ctrl_done, vif.warp_exit);
      end
      $fclose(wf);
    end
  end

  initial begin
    uvm_config_db#(simt_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
