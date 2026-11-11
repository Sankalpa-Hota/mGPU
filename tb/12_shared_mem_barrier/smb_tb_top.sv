module tb_top;
  import uvm_pkg::*;
  import smb_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  smb_interface vif (clk, rst_n);
  shared_mem #(.WORDS(WORDS), .NW(4)) u_smem (.clk(clk), .rst_n(rst_n), .req_valid(vif.req_valid), .req_ready(vif.req_ready),
    .req_we(vif.req_we), .req_mask(vif.req_mask), .req_addr(vif.req_addr), .req_wdata(vif.req_wdata), .req_warp(vif.req_warp),
    .req_rd(vif.req_rd), .rsp_valid(vif.rsp_valid), .rsp_we(vif.rsp_we), .rsp_warp(vif.rsp_warp), .rsp_rd(vif.rsp_rd),
    .rsp_mask(vif.rsp_mask), .rsp_data(vif.rsp_data), .last_passes(vif.last_passes));
  barrier #(.NW(4)) u_bar (.clk(clk), .rst_n(rst_n), .wl_mask(vif.wl_mask), .arrive_valid(vif.arrive_valid),
    .arrive_warp(vif.arrive_warp), .live(vif.live), .release_mask(vif.release_mask), .waiting(vif.waiting));
  smb_assertions u_chk (.clk(clk), .rst_n(rst_n), .req_valid(vif.req_valid), .req_ready(vif.req_ready), .rsp_valid(vif.rsp_valid),
    .release_mask(vif.release_mask), .waiting(vif.waiting), .live(vif.live));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | req_v rdy we mask     pend     | rsp_v passes data[0]  | live arrive w  waiting release");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b   %b  %b %b |  %b    %2d   %h |  %b   %b    %0d  %b    %b", cyc, vif.req_valid, vif.req_ready,
                  vif.req_we, vif.req_mask, u_smem.pend, vif.rsp_valid, vif.last_passes, vif.rsp_data[0], vif.live,
                  vif.arrive_valid, vif.arrive_warp, vif.waiting, vif.release_mask);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(smb_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
