module tb_top;
  import uvm_pkg::*;
  import xbar_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  xbar_interface vif (clk, rst_n);
  crossbar #(.N(4), .NB(2)) dut (.clk(clk), .rst_n(rst_n), .req_valid(vif.req_valid), .req_ready(vif.req_ready),
    .req_addr(vif.req_addr), .req_we(vif.req_we), .req_wdata(vif.req_wdata), .req_wstrb(vif.req_wstrb),
    .rsp_valid(vif.rsp_valid), .rsp_data(vif.rsp_data), .b_valid(vif.b_valid), .b_ready(vif.b_ready), .b_addr(vif.b_addr),
    .b_we(vif.b_we), .b_wdata(vif.b_wdata), .b_wstrb(vif.b_wstrb), .b_id(vif.b_id), .b_rsp_valid(vif.b_rsp_valid),
    .b_rsp_data(vif.b_rsp_data), .b_rsp_id(vif.b_rsp_id));
  xbar_assertions u_chk (.clk(clk), .rst_n(rst_n), .b_valid(vif.b_valid), .b_ready(vif.b_ready), .b_addr0(vif.b_addr[0]),
    .b_addr1(vif.b_addr[1]), .b_id0(vif.b_id[0]), .b_id1(vif.b_id[1]), .req_ready(vif.req_ready), .req_valid(vif.req_valid));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | req_v rdy  | b0: v r id addr     | b1: v r id addr     | b_rsp v ids | rsp_v");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d | %b %b | %b %b %0d %h | %b %b %0d %h | %b %0d %0d | %b", cyc, vif.req_valid, vif.req_ready,
                  vif.b_valid[0], vif.b_ready[0], vif.b_id[0], vif.b_addr[0], vif.b_valid[1], vif.b_ready[1], vif.b_id[1],
                  vif.b_addr[1], vif.b_rsp_valid, vif.b_rsp_id[0], vif.b_rsp_id[1], vif.rsp_valid);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(xbar_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
