module tb_top;
  import uvm_pkg::*;
  import mmu_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end
  mmu_interface vif (clk, rst_n);
  mmu #(.TLB_N(8)) dut (.clk(clk), .rst_n(rst_n), .enable(vif.enable), .ptbr(vif.ptbr), .tlb_invalidate(vif.tlb_invalidate),
    .req_valid(vif.req_valid), .req_ready(vif.req_ready), .req_addr(vif.req_addr), .req_we(vif.req_we), .req_wdata(vif.req_wdata),
    .req_wstrb(vif.req_wstrb), .rsp_valid(vif.rsp_valid), .rsp_data(vif.rsp_data), .rsp_err(vif.rsp_err),
    .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .mreq_addr(vif.mreq_addr), .mreq_we(vif.mreq_we),
    .mreq_wdata(vif.mreq_wdata), .mreq_wstrb(vif.mreq_wstrb), .mrsp_valid(vif.mrsp_valid), .mrsp_data(vif.mrsp_data),
    .fault_valid(vif.fault_valid), .fault_va(vif.fault_va), .fault_write(vif.fault_write), .fault_clear(vif.fault_clear),
    .stat_tlb_hit(vif.stat_tlb_hit), .stat_walk(vif.stat_walk));
  mmu_assertions u_chk (.clk(clk), .rst_n(rst_n), .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .rsp_valid(vif.rsp_valid),
    .rsp_err(vif.rsp_err), .fault_valid(vif.fault_valid), .fault_clear(vif.fault_clear), .mreq_addr(vif.mreq_addr), .rsp_data(vif.rsp_data));
  int wf; int cyc; string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | req_v r we va       | st | mreq_v r we pa       | mrsp | rsp_v err | tlb_hit walk | fault va       inval");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b  %b %h | %0d  |   %b    %b  %b %h |  %b   |  %b    %b  |   %b      %b   |  %b   %h  %b", cyc,
                  vif.req_valid, vif.req_ready, vif.req_we, vif.req_addr, dut.state, vif.mreq_valid, vif.mreq_ready, vif.mreq_we,
                  vif.mreq_addr, vif.mrsp_valid, vif.rsp_valid, vif.rsp_err, vif.stat_tlb_hit, vif.stat_walk, vif.fault_valid,
                  vif.fault_va, vif.tlb_invalidate);
      end
      $fclose(wf);
    end
  end
  initial begin
    uvm_config_db#(mmu_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
