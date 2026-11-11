module tb_top;
  import uvm_pkg::*;
  import l2_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  l2_interface vif (clk, rst_n);
  l2_cache #(.SETS(SETS), .NB(2), .IDW(2), .BANK(BANK)) dut (.clk(clk), .rst_n(rst_n), .req_valid(vif.req_valid),
    .req_ready(vif.req_ready), .req_addr(vif.req_addr), .req_we(vif.req_we), .req_wdata(vif.req_wdata), .req_wstrb(vif.req_wstrb),
    .req_id(vif.req_id), .rsp_valid(vif.rsp_valid), .rsp_data(vif.rsp_data), .rsp_id(vif.rsp_id), .flush_req(vif.flush_req),
    .flush_done(vif.flush_done), .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .mreq_addr(vif.mreq_addr),
    .mreq_we(vif.mreq_we), .mreq_wdata(vif.mreq_wdata), .mrsp_valid(vif.mrsp_valid), .mrsp_data(vif.mrsp_data),
    .mrsp_err(vif.mrsp_err), .busy(vif.busy));
  l2_assertions u_chk (.clk(clk), .rst_n(rst_n), .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .rsp_valid(vif.rsp_valid),
    .req_valid(vif.req_valid), .req_ready(vif.req_ready), .flush_req(vif.flush_req), .mreq_addr(vif.mreq_addr));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | req_v r we addr     id | st | mreq_v r we addr     | mrsp err | rsp_v id | flush done");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b  %b %h %0d | %0d |   %b    %b  %b %h |  %b   %b  |  %b   %0d |  %b    %b", cyc, vif.req_valid,
                  vif.req_ready, vif.req_we, vif.req_addr, vif.req_id, dut.state, vif.mreq_valid, vif.mreq_ready, vif.mreq_we,
                  vif.mreq_addr, vif.mrsp_valid, vif.mrsp_err, vif.rsp_valid, vif.rsp_id, vif.flush_req, vif.flush_done);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(l2_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
