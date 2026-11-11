// Streaming multiprocessor: 2 sub-cores, a shared instruction cache, a shared L1 data cache, and one memory
// port toward the crossbar. A workgroup launch names the sub-core (launch_sub) that runs it.
// invalidate (start of a kernel) clears the instruction cache and the L1.
module sm
  import mgpu_pkg::*;
(
  input  logic         clk,
  input  logic         rst_n,
  input  logic         launch_valid,
  input  logic         launch_sub,
  input  logic [31:0]  launch_wg_id,
  input  logic [2:0]   launch_nwarps,
  input  logic [31:0]  launch_pc,
  input  logic [31:0]  launch_arg,
  output logic [1:0]   wg_done,
  output logic         busy,
  input  logic         invalidate,
  output logic         mreq_valid,
  input  logic         mreq_ready,
  output logic [31:0]  mreq_addr,
  output logic         mreq_we,
  output logic [255:0] mreq_wdata,
  output logic [31:0]  mreq_wstrb,
  input  logic         mrsp_valid,
  input  logic [255:0] mrsp_data,
  output logic [1:0]   stat_issue,
  output logic         stat_l1_hit_pulse,
  output logic         stat_overflow
);
  // sub-core <-> icache
  logic [1:0]  f_valid, f_ready, f_rsp_valid;
  logic [31:0] f_pc [2];
  logic [31:0] f_rsp_instr;
  // sub-core <-> L1 arbiter
  logic [1:0]   l_valid, l_ready, l_rsp_valid;
  logic [31:0]  l_addr [2];
  logic         l_we [2];
  logic [255:0] l_wdata [2];
  logic [31:0]  l_wstrb [2];
  logic [255:0] l_rsp_data;
  logic [1:0]   active, ovf;
  logic [2:0]   depth [2];
  logic [3:0]   passes [2], lines [2];

`ifdef BUG_L1_NO_INVALIDATE
  logic l1_inv;
  assign l1_inv = 1'b0;
`else
  logic l1_inv;
  assign l1_inv = invalidate;
`endif

  for (genvar s = 0; s < 2; s++) begin : g_sub
    subcore u_sub (
      .clk(clk), .rst_n(rst_n), .launch_valid(launch_valid && launch_sub == s), .launch_wg_id(launch_wg_id),
      .launch_nwarps(launch_nwarps), .launch_pc(launch_pc), .launch_arg(launch_arg), .wg_done(wg_done[s]), .active(active[s]),
      .f_valid(f_valid[s]), .f_ready(f_ready[s]), .f_pc(f_pc[s]), .f_rsp_valid(f_rsp_valid[s]), .f_rsp_instr(f_rsp_instr),
      .mreq_valid(l_valid[s]), .mreq_ready(l_ready[s]), .mreq_addr(l_addr[s]), .mreq_we(l_we[s]), .mreq_wdata(l_wdata[s]),
      .mreq_wstrb(l_wstrb[s]), .mrsp_valid(l_rsp_valid[s]), .mrsp_data(l_rsp_data),
      .stat_issue(stat_issue[s]), .stat_simt_depth(depth[s]), .stat_smem_passes(passes[s]), .stat_lsu_lines(lines[s]),
      .stat_overflow(ovf[s]));
  end
  assign busy = |active;
  assign stat_overflow = |ovf;

  // instruction cache (shared by the two sub-cores)
  logic         ic_mreq_valid, ic_mreq_ready, ic_mrsp_valid;
  logic [31:0]  ic_mreq_addr;
  icache #(.NPORT(2), .LINES(16)) u_icache (
    .clk(clk), .rst_n(rst_n), .req_valid(f_valid), .req_ready(f_ready), .req_pc(f_pc), .rsp_valid(f_rsp_valid),
    .rsp_instr(f_rsp_instr), .invalidate(invalidate), .mreq_valid(ic_mreq_valid), .mreq_ready(ic_mreq_ready),
    .mreq_addr(ic_mreq_addr), .mrsp_valid(ic_mrsp_valid), .mrsp_data(mrsp_data));

  // two LSUs -> L1
  logic         l1_req_valid, l1_req_ready, l1_req_we, l1_rsp_valid;
  logic [31:0]  l1_req_addr, l1_req_wstrb;
  logic [255:0] l1_req_wdata, l1_rsp_data;
  line_arbiter #(.N(2)) u_l1_arb (
    .clk(clk), .rst_n(rst_n), .in_valid(l_valid), .in_ready(l_ready), .in_addr(l_addr), .in_we(l_we), .in_wdata(l_wdata),
    .in_wstrb(l_wstrb), .in_rsp_valid(l_rsp_valid), .in_rsp_data(l_rsp_data),
    .out_valid(l1_req_valid), .out_ready(l1_req_ready), .out_addr(l1_req_addr), .out_we(l1_req_we), .out_wdata(l1_req_wdata),
    .out_wstrb(l1_req_wstrb), .out_rsp_valid(l1_rsp_valid), .out_rsp_data(l1_rsp_data));

  logic         d_mreq_valid, d_mreq_ready, d_mreq_we, d_mrsp_valid, l1_hit;
  logic [31:0]  d_mreq_addr, d_mreq_wstrb;
  logic [255:0] d_mreq_wdata;
  l1_dcache #(.SETS(16)) u_l1 (
    .clk(clk), .rst_n(rst_n), .req_valid(l1_req_valid), .req_ready(l1_req_ready), .req_addr(l1_req_addr), .req_we(l1_req_we),
    .req_wdata(l1_req_wdata), .req_wstrb(l1_req_wstrb), .rsp_valid(l1_rsp_valid), .rsp_data(l1_rsp_data), .invalidate(l1_inv),
    .mreq_valid(d_mreq_valid), .mreq_ready(d_mreq_ready), .mreq_addr(d_mreq_addr), .mreq_we(d_mreq_we),
    .mreq_wdata(d_mreq_wdata), .mreq_wstrb(d_mreq_wstrb), .mrsp_valid(d_mrsp_valid), .mrsp_data(mrsp_data), .last_hit(l1_hit));
  assign stat_l1_hit_pulse = l1_rsp_valid && l1_hit;

  // icache fills + L1 traffic -> SM memory port
  logic [1:0]   m_valid, m_ready, m_rsp_valid;
  logic [31:0]  m_addr [2];
  logic         m_we [2];
  logic [255:0] m_wdata [2];
  logic [31:0]  m_wstrb [2];
  logic [255:0] m_rsp_data;
  assign m_valid = {d_mreq_valid, ic_mreq_valid};
  assign m_addr  = '{ic_mreq_addr, d_mreq_addr};
  assign m_we    = '{1'b0, d_mreq_we};
  assign m_wdata = '{256'd0, d_mreq_wdata};
  assign m_wstrb = '{32'd0, d_mreq_wstrb};
  assign ic_mreq_ready = m_ready[0];
  assign d_mreq_ready  = m_ready[1];
  assign ic_mrsp_valid = m_rsp_valid[0];
  assign d_mrsp_valid  = m_rsp_valid[1];
  line_arbiter #(.N(2)) u_mem_arb (
    .clk(clk), .rst_n(rst_n), .in_valid(m_valid), .in_ready(m_ready), .in_addr(m_addr), .in_we(m_we), .in_wdata(m_wdata),
    .in_wstrb(m_wstrb), .in_rsp_valid(m_rsp_valid), .in_rsp_data(m_rsp_data),
    .out_valid(mreq_valid), .out_ready(mreq_ready), .out_addr(mreq_addr), .out_we(mreq_we), .out_wdata(mreq_wdata),
    .out_wstrb(mreq_wstrb), .out_rsp_valid(mrsp_valid), .out_rsp_data(mrsp_data));
endmodule
