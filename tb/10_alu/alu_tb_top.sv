module tb_top;
  import uvm_pkg::*;
  import alu_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  alu_interface vif (clk, rst_n);
  alu #(.NW(4)) dut (
    .clk(clk), .rst_n(rst_n), .ex_valid(vif.ex_valid), .ex_ready(vif.ex_ready), .ex_warp(vif.ex_warp), .ex_instr(vif.ex_instr),
    .ex_pc(vif.ex_pc), .ex_mask(vif.ex_mask), .ex_a(vif.ex_a), .ex_b(vif.ex_b),
    .ctx_wg_id(vif.ctx_wg_id), .ctx_nwarps(vif.ctx_nwarps), .ctx_arg(vif.ctx_arg),
    .wb_valid(vif.wb_valid), .wb_ready(vif.wb_ready), .wb_warp(vif.wb_warp), .wb_rd(vif.wb_rd), .wb_mask(vif.wb_mask), .wb_data(vif.wb_data),
    .br_valid(vif.br_valid), .br_warp(vif.br_warp), .br_instr(vif.br_instr), .br_pc(vif.br_pc), .br_taken(vif.br_taken));
  alu_assertions u_chk (.clk(clk), .rst_n(rst_n), .wb_valid(vif.wb_valid), .wb_ready(vif.wb_ready), .br_valid(vif.br_valid),
    .ex_valid(vif.ex_valid), .ex_ready(vif.ex_ready), .wb_d0(vif.wb_data[0]), .ex_instr(vif.ex_instr));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | ex_v rdy instr    a[0]     b[0]     | wb_v rdy rd data[0]  | br_v taken");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b  %h %h %h |  %b    %b  %2d %h |  %b   %b", cyc, vif.ex_valid, vif.ex_ready, vif.ex_instr,
                  vif.ex_a[0], vif.ex_b[0], vif.wb_valid, vif.wb_ready, vif.wb_rd, vif.wb_data[0], vif.br_valid, vif.br_taken);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(alu_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
