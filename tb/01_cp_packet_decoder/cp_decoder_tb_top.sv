module tb_top;
  import uvm_pkg::*;
  import cp_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end

  cp_if vif (clk, rst_n);

  cp_packet_decoder dut (
    .clk(clk), .rst_n(rst_n),
    .dw_valid(vif.dw_valid), .dw_ready(vif.dw_ready), .dw_data(vif.dw_data),
    .out_ready(vif.out_ready),
    .reg_wr_en(vif.reg_wr_en), .reg_wr_addr(vif.reg_wr_addr), .reg_wr_data(vif.reg_wr_data),
    .op_valid(vif.op_valid), .op_code(vif.op_code), .op_data(vif.op_data), .op_last(vif.op_last),
    .bad_pkt(vif.bad_pkt), .busy(vif.busy));

  cp_assertions u_chk (
    .clk(clk), .rst_n(rst_n),
    .dw_valid(vif.dw_valid), .dw_ready(vif.dw_ready), .out_ready(vif.out_ready), .busy(vif.busy),
    .dw_data(vif.dw_data), .reg_wr_en(vif.reg_wr_en), .op_valid(vif.op_valid), .op_last(vif.op_last),
    .bad_pkt(vif.bad_pkt));

  // Text waveform: one line per cycle for the first 200 cycles after reset.
  int    wf;
  int    cyc;
  string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | dw_v dw_r dw_data  | out_r | reg_we addr  data     | op_v op data     last | bad busy");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b   %h |   %b   |   %b   %h %h |  %b   %h %h  %b   |  %b   %b",
                  cyc, vif.dw_valid, vif.dw_ready, vif.dw_data, vif.out_ready,
                  vif.reg_wr_en, vif.reg_wr_addr, vif.reg_wr_data,
                  vif.op_valid, vif.op_code, vif.op_data, vif.op_last, vif.bad_pkt, vif.busy);
      end
      $fclose(wf);
    end
  end

  initial begin
    uvm_config_db#(virtual cp_if)::set(null, "uvm_test_top.env.agt.*", "vif", vif);
    run_test();
  end
endmodule
