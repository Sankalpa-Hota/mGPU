module tb_top;
  import uvm_pkg::*;
  import l1_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  l1_interface vif (clk, rst_n);
  l1_dcache #(.SETS(SETS)) dut (.clk(clk), .rst_n(rst_n), .req_valid(vif.req_valid), .req_ready(vif.req_ready),
    .req_addr(vif.req_addr), .req_we(vif.req_we), .req_wdata(vif.req_wdata), .req_wstrb(vif.req_wstrb),
    .rsp_valid(vif.rsp_valid), .rsp_data(vif.rsp_data), .invalidate(vif.invalidate),
    .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .mreq_addr(vif.mreq_addr), .mreq_we(vif.mreq_we),
    .mreq_wdata(vif.mreq_wdata), .mreq_wstrb(vif.mreq_wstrb), .mrsp_valid(vif.mrsp_valid), .mrsp_data(vif.mrsp_data),
    .last_hit(vif.last_hit));
  l1_assertions u_chk (.clk(clk), .rst_n(rst_n), .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready),
    .rsp_valid(vif.rsp_valid), .req_valid(vif.req_valid), .req_ready(vif.req_ready), .mreq_addr(vif.mreq_addr));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | req_v rdy we addr     | st hit | mreq_v r we addr     | mrsp | rsp_v data[31:0] | inval");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b   %b %h | %0d   %b |   %b    %b  %b %h |  %b   |  %b   %h  |  %b", cyc, vif.req_valid,
                  vif.req_ready, vif.req_we, vif.req_addr, dut.state, dut.hit, vif.mreq_valid, vif.mreq_ready, vif.mreq_we,
                  vif.mreq_addr, vif.mrsp_valid, vif.rsp_valid, vif.rsp_data[31:0], vif.invalidate);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(l1_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
