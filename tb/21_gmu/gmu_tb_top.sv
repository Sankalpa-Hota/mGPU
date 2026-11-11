module tb_top;
  import uvm_pkg::*;
  import gmu_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  gmu_interface vif (clk, rst_n);
  gmu #(.NSM(2), .WAKE_CYCLES(WAKE)) dut (.clk(clk), .rst_n(rst_n), .idle_limit(vif.idle_limit), .sm_busy(vif.sm_busy),
    .sm_want(vif.sm_want), .sm_avail(vif.sm_avail), .sm_power(vif.sm_power), .stat_off_pulse(vif.stat_off_pulse),
    .stat_wake_pulse(vif.stat_wake_pulse));
  gmu_assertions u_chk (.clk(clk), .rst_n(rst_n), .sm_busy(vif.sm_busy), .sm_power(vif.sm_power), .sm_avail(vif.sm_avail));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | limit | busy want | st0 idle0 wake0 | st1 idle1 | avail power");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 300) break;
        $fdisplay(wf, "%5d | %4d  |  %b   %b  |  %0d   %3d    %0d   |  %0d   %3d  |  %b    %b", cyc, vif.idle_limit, vif.sm_busy,
                  vif.sm_want, dut.st[0], dut.idle[0], dut.wake[0], dut.st[1], dut.idle[1], vif.sm_avail, vif.sm_power);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(gmu_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
