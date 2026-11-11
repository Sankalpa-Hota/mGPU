module tb_top;
  import uvm_pkg::*;
  import icache_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end

  icache_interface vif (clk, rst_n);

  icache #(.NPORT(2), .LINES(LINES)) dut (
    .clk(clk), .rst_n(rst_n), .req_valid(vif.req_valid), .req_ready(vif.req_ready), .req_pc(vif.req_pc),
    .rsp_valid(vif.rsp_valid), .rsp_instr(vif.rsp_instr), .invalidate(vif.invalidate),
    .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .mreq_addr(vif.mreq_addr),
    .mrsp_valid(vif.mrsp_valid), .mrsp_data(vif.mrsp_data));

  icache_assertions u_chk (.clk(clk), .rst_n(rst_n), .req_valid(vif.req_valid), .req_ready(vif.req_ready),
    .rsp_valid(vif.rsp_valid), .req_pc0(vif.req_pc[0]), .req_pc1(vif.req_pc[1]),
    .mreq_valid(vif.mreq_valid), .mreq_ready(vif.mreq_ready), .mreq_addr(vif.mreq_addr));

  int    wf;
  int    cyc;
  int    wfrom;
  string wname;
  initial begin
    if ($value$plusargs("WAVE=%s", wname)) begin
      wf = $fopen(wname, "w");
      $fdisplay(wf, "cycle | req_v rdy pc0      pc1      | st | mreq_v r addr     | mrsp | rsp_v instr    | inval");
      if (!$value$plusargs("WAVE_FROM=%d", wfrom)) wfrom = 0;
      forever begin
        @(negedge clk);
        if (!rst_n) continue;
        cyc++;
        if (cyc <= wfrom) continue;
        if (cyc > wfrom + 200) break;
        $fdisplay(wf, "%5d |  %b    %b  %h %h | %0d  |   %b    %b %h |  %b   |  %b   %h |  %b",
                  cyc, vif.req_valid, vif.req_ready, vif.req_pc[0], vif.req_pc[1], dut.state, vif.mreq_valid,
                  vif.mreq_ready, vif.mreq_addr, vif.mrsp_valid, vif.rsp_valid, vif.rsp_instr, vif.invalidate);
      end
      $fclose(wf);
    end
  end

  initial begin
    uvm_config_db#(icache_vif_t)::set(null, "uvm_test_top*", "vif", vif);
    run_test();
  end
endmodule
