module tb_top;
  import uvm_pkg::*;
  import ring_fetch_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end

  ring_fetch_interface #(RING_LOG2) vif (clk, rst_n);

  cp_ring_fetch #(.RING_LOG2(RING_LOG2), .FIFO_DEPTH(16)) dut (
    .clk(clk), .rst_n(rst_n), .ring_base(vif.ring_base), .wptr(vif.wptr), .rptr(vif.rptr),
    .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .mreq_addr(vif.mreq_addr),
    .mrsp_valid(vif.mrsp_valid), .mrsp_data(vif.mrsp_data),
    .dw_valid(vif.dw_valid), .dw_ready(vif.dw_ready), .dw_data(vif.dw_data), .busy(vif.busy));

  ring_fetch_assertions #(RING_LOG2, 16) u_chk (
    .clk(clk), .rst_n(rst_n), .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .mrsp_valid(vif.mrsp_valid),
    .mreq_addr(vif.mreq_addr), .dw_valid(vif.dw_valid), .dw_ready(vif.dw_ready), .dw_data(vif.dw_data),
    .wptr(vif.wptr), .rptr(vif.rptr), .busy(vif.busy), .fifo_count(dut.count));

  int    wf;
  int    cyc;
  string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | wptr rptr fptr st | mreq_v mreq_r addr     | mrsp_v | fifo | dw_v dw_r dw_data  | busy");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %2d   %2d   %2d   %0d |   %b      %b   %h |   %b    |  %2d  |  %b    %b   %h |  %b",
                  cyc, vif.wptr, vif.rptr, dut.fptr, dut.state, vif.mreq_valid, vif.mreq_ready, vif.mreq_addr,
                  vif.mrsp_valid, dut.count, vif.dw_valid, vif.dw_ready, vif.dw_data, vif.busy);
      end
      $fclose(wf);
    end
  end

  initial begin
    uvm_config_db#(ring_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
