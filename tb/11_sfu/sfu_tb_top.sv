module tb_top;
  import uvm_pkg::*;
  import sfu_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  sfu_interface vif (clk, rst_n);
  sfu #(.NW(4)) dut (.clk(clk), .rst_n(rst_n), .ex_valid(vif.ex_valid), .ex_ready(vif.ex_ready), .ex_warp(vif.ex_warp),
    .ex_instr(vif.ex_instr), .ex_mask(vif.ex_mask), .ex_a(vif.ex_a), .ex_b(vif.ex_b), .wb_valid(vif.wb_valid),
    .wb_ready(vif.wb_ready), .wb_warp(vif.wb_warp), .wb_rd(vif.wb_rd), .wb_mask(vif.wb_mask), .wb_data(vif.wb_data), .busy(vif.busy));
  sfu_assertions u_chk (.clk(clk), .rst_n(rst_n), .ex_valid(vif.ex_valid), .ex_ready(vif.ex_ready), .wb_valid(vif.wb_valid),
    .wb_ready(vif.wb_ready), .busy(vif.busy), .wb_d0(vif.wb_data[0]));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | ex_v rdy op a[0]     b[0]     | run cnt quo[0]   rem[0]    sq_res[0] | wb_v rdy data[0]");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b  %h %h %h |  %b  %2d %h %h %h |  %b    %b  %h", cyc, vif.ex_valid, vif.ex_ready,
                  vif.ex_instr[31:26], vif.ex_a[0], vif.ex_b[0], dut.run, dut.cnt, dut.quo[0], dut.rem[0][31:0], dut.sq_res[0],
                  vif.wb_valid, vif.wb_ready, vif.wb_data[0]);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(sfu_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
