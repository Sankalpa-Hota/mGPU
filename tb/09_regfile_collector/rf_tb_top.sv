module tb_top;
  import uvm_pkg::*;
  import rf_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end

  rf_interface vif (clk, rst_n);

  regfile_collector #(.NW(4), .NWB(3)) dut (
    .clk(clk), .rst_n(rst_n), .wl_mask(vif.wl_mask),
    .is_valid(vif.is_valid), .is_ready(vif.is_ready), .is_warp(vif.is_warp), .is_instr(vif.is_instr), .is_pc(vif.is_pc), .is_mask(vif.is_mask),
    .ex_valid(vif.ex_valid), .ex_unit(vif.ex_unit), .ex_ready(vif.ex_ready), .ex_warp(vif.ex_warp), .ex_instr(vif.ex_instr),
    .ex_pc(vif.ex_pc), .ex_mask(vif.ex_mask), .ex_a(vif.ex_a), .ex_b(vif.ex_b),
    .wb_valid(vif.wb_valid), .wb_ready(vif.wb_ready), .wb_warp(vif.wb_warp), .wb_rd(vif.wb_rd), .wb_mask(vif.wb_mask), .wb_data(vif.wb_data));

  rf_assertions u_chk (.clk(clk), .rst_n(rst_n), .is_valid(vif.is_valid), .is_ready(vif.is_ready), .ex_valid(vif.ex_valid),
    .ex_ready(vif.ex_ready), .ex_unit(vif.ex_unit), .ex_instr(vif.ex_instr), .rd_a(dut.rd_a), .rd_b(dut.rd_b),
    .bank_a(dut.bank(dut.c_warp, dut.ra)), .bank_b(dut.bank(dut.c_warp, dut.rb)));

  // handshake flags of the cycle that just ended, used by the drivers to know if their offer was taken
  bit accepted_last, ex_fired_last;
  bit [1:0] ex_fired_warp;
  bit [2:0] wb_accepted_last;
  always @(posedge clk) begin
    accepted_last    <= vif.is_valid && vif.is_ready;
    ex_fired_last    <= vif.ex_valid && vif.ex_ready[vif.ex_unit];
    ex_fired_warp    <= vif.ex_warp;
    wb_accepted_last <= vif.wb_valid & vif.wb_ready;
  end

  int    wf;
  int    cyc;
  string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | is_v rdy w instr    | occ needA needB | ex_v unit rdy  instr    a[0]     b[0]     | wb_v wb_r");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b   %b  %0d %h |  %b    %b     %b   |  %b    %0d  %b %h %h %h | %b  %b",
                  cyc, vif.is_valid, vif.is_ready, vif.is_warp, vif.is_instr, dut.occ, dut.need_a, dut.need_b,
                  vif.ex_valid, vif.ex_unit, vif.ex_ready, vif.ex_instr, vif.ex_a[0], vif.ex_b[0], vif.wb_valid, vif.wb_ready);
      end
      $fclose(wf);
    end
  end

  initial begin
    uvm_config_db#(rf_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
