module tb_top;
  import uvm_pkg::*;
  import top_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  top_interface vif (clk, rst_n);
  mgpu_system dut (.clk(clk), .rst_n(rst_n), .psel(vif.psel), .penable(vif.penable), .pwrite(vif.pwrite), .paddr(vif.paddr),
    .pwdata(vif.pwdata), .prdata(vif.prdata), .pready(vif.pready), .pslverr(vif.pslverr), .irq(vif.irq),
    .mmu_fault(vif.mmu_fault), .mmu_fault_va(vif.mmu_fault_va));
  top_assertions u_chk (.clk(clk), .rst_n(rst_n), .sm_busy(dut.u_gpu.sm_busy), .sm_power(dut.u_gpu.sm_power),
    .sm0_ovf(dut.u_gpu.s_ovf[0]), .sm1_ovf(dut.u_gpu.s_ovf[1]), .bad_pkt(dut.u_gpu.bad_pkt), .bad_op(dut.u_gpu.bad_op));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | wptr rptr | op_v code | disp | launch slot wg | sm_busy power | issue0 issue1 | l2 busy flush | mmu walk | axi ar aw | busy | irq");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 3000) break;
        $fdisplay(wf, "%5d | %4d %4d |  %b   %h  |  %b   |   %b     %0d  %2d |   %b     %b  |   %b     %b   |   %b     %b   |   %b    |  %b  %b  | %b | %b", cyc,
                  dut.u_gpu.ring_wptr, dut.u_gpu.ring_rptr, dut.u_gpu.op_valid, dut.u_gpu.op_code, dut.u_gpu.kernel_start,
                  dut.u_gpu.launch_valid, dut.u_gpu.launch_slot, dut.u_gpu.launch_wg_id, dut.u_gpu.sm_busy, dut.u_gpu.sm_power,
                  dut.u_gpu.s_issue[0], dut.u_gpu.s_issue[1], dut.u_gpu.l2_busy, dut.u_gpu.flush_pend, dut.u_gpu.walk,
                  dut.arvalid && dut.arready, dut.awvalid && dut.awready, dut.u_gpu.busy_bits, vif.irq);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(top_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
