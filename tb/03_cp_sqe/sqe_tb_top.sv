module tb_top;
  import uvm_pkg::*;
  import sqe_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end

  sqe_interface vif (clk, rst_n);

  cp_sqe #(.NBUSY(8), .SETTLE(SETTLE)) dut (
    .clk(clk), .rst_n(rst_n),
    .op_valid(vif.op_valid), .op_ready(vif.op_ready), .op_code(vif.op_code), .op_data(vif.op_data), .op_last(vif.op_last),
    .disp_valid(vif.disp_valid), .disp_ready(vif.disp_ready), .disp_num_wg(vif.disp_num_wg), .busy_in(vif.busy_in),
    .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .mreq_addr(vif.mreq_addr), .mreq_we(vif.mreq_we),
    .mreq_wdata(vif.mreq_wdata), .mreq_wstrb(vif.mreq_wstrb), .mrsp_valid(vif.mrsp_valid),
    .irq(vif.irq), .op_done(vif.op_done), .bad_op(vif.bad_op), .busy(vif.busy));

  sqe_assertions u_chk (
    .clk(clk), .rst_n(rst_n), .op_valid(vif.op_valid), .op_ready(vif.op_ready), .op_last(vif.op_last),
    .op_code(vif.op_code), .op_data(vif.op_data),
    .disp_valid(vif.disp_valid), .disp_ready(vif.disp_ready), .disp_num_wg(vif.disp_num_wg),
    .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .mreq_addr(vif.mreq_addr), .mreq_wstrb(vif.mreq_wstrb),
    .irq(vif.irq), .op_done(vif.op_done), .bad_op(vif.bad_op), .busy(vif.busy));

  int    wf;
  int    cyc;
  string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | op_v op_r code data     last | st | disp_v disp_r nwg | busy_in | mreq_v mreq_r addr     wstrb    | ack | irq done bad");
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc > 200) break;
        $fdisplay(wf, "%5d |  %b    %b   %h  %h  %b   | %0d  |   %b      %b    %3d |   %h    |   %b      %b   %h %h |  %b  |  %b   %b    %b",
                  cyc, vif.op_valid, vif.op_ready, vif.op_code, vif.op_data, vif.op_last, dut.state,
                  vif.disp_valid, vif.disp_ready, vif.disp_num_wg, vif.busy_in, vif.mreq_valid, vif.mreq_ready,
                  vif.mreq_addr, vif.mreq_wstrb, vif.mrsp_valid, vif.irq, vif.op_done, vif.bad_op);
      end
      $fclose(wf);
    end
  end

  initial begin
    uvm_config_db#(sqe_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
