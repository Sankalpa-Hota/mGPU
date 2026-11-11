// One sub-core: runs one workgroup (up to 4 warps of 8 threads).
//   warp_scheduler -> regfile_collector -> {alu, sfu, lsu, barrier}; simt_stack owns pc and masks;
//   lsu -> shared_mem (LDS/STS) and the SM's L1 port (LD/ST).
// wg_done pulses when every warp has exited and the LSU and SFU are idle (all stores acknowledged).
module subcore
  import mgpu_pkg::*;
(
  input  logic         clk,
  input  logic         rst_n,
  input  logic         launch_valid,
  input  logic [31:0]  launch_wg_id,
  input  logic [2:0]   launch_nwarps,
  input  logic [31:0]  launch_pc,
  input  logic [31:0]  launch_arg,
  output logic         wg_done,
  output logic         active,
  // instruction cache port
  output logic         f_valid,
  input  logic         f_ready,
  output logic [31:0]  f_pc,
  input  logic         f_rsp_valid,
  input  logic [31:0]  f_rsp_instr,
  // L1 port
  output logic         mreq_valid,
  input  logic         mreq_ready,
  output logic [31:0]  mreq_addr,
  output logic         mreq_we,
  output logic [255:0] mreq_wdata,
  output logic [31:0]  mreq_wstrb,
  input  logic         mrsp_valid,
  input  logic [255:0] mrsp_data,
  // statistics
  output logic         stat_issue,
  output logic [2:0]   stat_simt_depth,
  output logic [3:0]   stat_smem_passes,
  output logic [3:0]   stat_lsu_lines,
  output logic         stat_overflow
);
  localparam int NW = NWARP;
  localparam int WW = $clog2(NW);

  // workgroup context
  logic [31:0] ctx_wg, ctx_arg;
  logic [2:0]  ctx_nw;
  logic [NW-1:0] wl_mask;
  assign wl_mask = launch_valid ? NW'((1 << launch_nwarps) - 1) : '0;

  // SIMT
  logic [31:0]      pc   [NW];
  logic [LANES-1:0] mask [NW];
  logic [NW-1:0]    live, simt_done, warp_exit, adv_sched, adv_all, ctrl_done_all, release_mask, waiting;
  logic             br_valid;
  logic [WW-1:0]    br_warp;
  logic [31:0]      br_instr, br_pc;
  logic [LANES-1:0] br_taken;
  logic [2:0]       depth [NW];
  assign adv_all       = adv_sched | release_mask;
  assign ctrl_done_all = simt_done | release_mask;

  simt_stack #(.NW(NW), .DEPTH(7)) u_simt (
    .clk(clk), .rst_n(rst_n), .wl_mask(wl_mask), .wl_pc(launch_pc), .adv_mask(adv_all),
    .br_valid(br_valid), .br_warp(br_warp), .br_instr(br_instr), .br_pc(br_pc), .br_taken(br_taken),
    .pc(pc), .mask(mask), .live(live), .ctrl_done(simt_done), .warp_exit(warp_exit), .overflow(stat_overflow), .depth(depth));

  // scheduler
  logic             is_valid, is_ready;
  logic [WW-1:0]    is_warp;
  logic [31:0]      is_instr, is_pc;
  logic [2:0]       wbv, wbr;
  logic [WW-1:0]    wb_warp [3];
  logic [3:0]       wb_rd   [3];
  logic [LANES-1:0] wb_mask [3];
  logic [31:0]      wb_data [3][LANES];
  logic [2:0]       wb_fire;
  logic [NW-1:0]    elig;
  logic             sched_idle;
  assign wb_fire = wbv & wbr;

  warp_scheduler #(.NW(NW), .NWB(3)) u_sched (
    .clk(clk), .rst_n(rst_n), .wl_mask(wl_mask), .live(live), .pc(pc),
    .f_valid(f_valid), .f_ready(f_ready), .f_pc(f_pc), .f_rsp_valid(f_rsp_valid), .f_rsp_instr(f_rsp_instr),
    .is_valid(is_valid), .is_ready(is_ready), .is_warp(is_warp), .is_instr(is_instr), .is_pc(is_pc),
    .adv_mask(adv_sched), .wb_valid(wb_fire), .wb_warp(wb_warp), .wb_rd(wb_rd), .ctrl_done(ctrl_done_all),
    .elig(elig), .idle(sched_idle));
  assign stat_issue = is_valid && is_ready;

  // register file + collector
  logic             ex_valid;
  logic [1:0]       ex_unit;
  logic [3:0]       ex_ready;
  logic [WW-1:0]    ex_warp;
  logic [31:0]      ex_instr, ex_pc;
  logic [LANES-1:0] ex_mask;
  logic [31:0]      ex_a [LANES];
  logic [31:0]      ex_b [LANES];
`ifdef BUG_MASK_NOT_PASSED
  logic [LANES-1:0] issue_mask;
  assign issue_mask = '1;
`else
  logic [LANES-1:0] issue_mask;
  assign issue_mask = mask[is_warp];
`endif

  regfile_collector #(.NW(NW), .NWB(3)) u_rf (
    .clk(clk), .rst_n(rst_n), .wl_mask(wl_mask),
    .is_valid(is_valid), .is_ready(is_ready), .is_warp(is_warp), .is_instr(is_instr), .is_pc(is_pc), .is_mask(issue_mask),
    .ex_valid(ex_valid), .ex_unit(ex_unit), .ex_ready(ex_ready), .ex_warp(ex_warp), .ex_instr(ex_instr), .ex_pc(ex_pc),
    .ex_mask(ex_mask), .ex_a(ex_a), .ex_b(ex_b),
    .wb_valid(wbv), .wb_ready(wbr), .wb_warp(wb_warp), .wb_rd(wb_rd), .wb_mask(wb_mask), .wb_data(wb_data));

  // ALU (also branches)
  logic alu_ready;
  alu #(.NW(NW)) u_alu (
    .clk(clk), .rst_n(rst_n), .ex_valid(ex_valid && ex_unit == 2'd0), .ex_ready(alu_ready), .ex_warp(ex_warp),
    .ex_instr(ex_instr), .ex_pc(ex_pc), .ex_mask(ex_mask), .ex_a(ex_a), .ex_b(ex_b),
    .ctx_wg_id(ctx_wg), .ctx_nwarps(ctx_nw), .ctx_arg(ctx_arg),
    .wb_valid(wbv[0]), .wb_ready(wbr[0]), .wb_warp(wb_warp[0]), .wb_rd(wb_rd[0]), .wb_mask(wb_mask[0]), .wb_data(wb_data[0]),
    .br_valid(br_valid), .br_warp(br_warp), .br_instr(br_instr), .br_pc(br_pc), .br_taken(br_taken));

  // SFU
  logic sfu_ready, sfu_busy;
  sfu #(.NW(NW)) u_sfu (
    .clk(clk), .rst_n(rst_n), .ex_valid(ex_valid && ex_unit == 2'd1), .ex_ready(sfu_ready), .ex_warp(ex_warp),
    .ex_instr(ex_instr), .ex_mask(ex_mask), .ex_a(ex_a), .ex_b(ex_b),
    .wb_valid(wbv[1]), .wb_ready(wbr[1]), .wb_warp(wb_warp[1]), .wb_rd(wb_rd[1]), .wb_mask(wb_mask[1]), .wb_data(wb_data[1]),
    .busy(sfu_busy));

  // LSU + shared memory
  logic lsu_ready, lsu_busy;
  logic             sm_valid, sm_ready, sm_we, sm_rsp_valid;
  logic [LANES-1:0] sm_mask;
  logic [31:0]      sm_addr [LANES];
  logic [31:0]      sm_wdata [LANES];
  logic [31:0]      sm_rsp_data [LANES];
  lsu #(.NW(NW)) u_lsu (
    .clk(clk), .rst_n(rst_n), .ex_valid(ex_valid && ex_unit == 2'd2), .ex_ready(lsu_ready), .ex_warp(ex_warp),
    .ex_instr(ex_instr), .ex_mask(ex_mask), .ex_a(ex_a), .ex_b(ex_b),
    .sm_valid(sm_valid), .sm_ready(sm_ready), .sm_we(sm_we), .sm_mask(sm_mask), .sm_addr(sm_addr), .sm_wdata(sm_wdata),
    .sm_rsp_valid(sm_rsp_valid), .sm_rsp_data(sm_rsp_data),
    .mreq_valid(mreq_valid), .mreq_ready(mreq_ready), .mreq_addr(mreq_addr), .mreq_we(mreq_we), .mreq_wdata(mreq_wdata),
    .mreq_wstrb(mreq_wstrb), .mrsp_valid(mrsp_valid), .mrsp_data(mrsp_data),
    .wb_valid(wbv[2]), .wb_ready(wbr[2]), .wb_warp(wb_warp[2]), .wb_rd(wb_rd[2]), .wb_mask(wb_mask[2]), .wb_data(wb_data[2]),
    .busy(lsu_busy), .last_lines(stat_lsu_lines));

  logic sm_rsp_we;
  logic [WW-1:0] sm_rsp_warp;
  logic [3:0] sm_rsp_rd;
  logic [LANES-1:0] sm_rsp_mask;
  shared_mem #(.WORDS(128), .NW(NW)) u_smem (
    .clk(clk), .rst_n(rst_n), .req_valid(sm_valid), .req_ready(sm_ready), .req_we(sm_we), .req_mask(sm_mask),
    .req_addr(sm_addr), .req_wdata(sm_wdata), .req_warp('0), .req_rd('0),
    .rsp_valid(sm_rsp_valid), .rsp_we(sm_rsp_we), .rsp_warp(sm_rsp_warp), .rsp_rd(sm_rsp_rd), .rsp_mask(sm_rsp_mask),
    .rsp_data(sm_rsp_data), .last_passes(stat_smem_passes));

  // barrier: BAR goes through the collector to "unit 3", which is always ready
  barrier #(.NW(NW)) u_bar (
    .clk(clk), .rst_n(rst_n), .wl_mask(wl_mask), .arrive_valid(ex_valid && ex_unit == 2'd3), .arrive_warp(ex_warp),
    .live(live), .release_mask(release_mask), .waiting(waiting));

  assign ex_ready = {1'b1, lsu_ready, sfu_ready, alu_ready};

  always_comb begin
    stat_simt_depth = '0;
    for (int w = 0; w < NW; w++) if (depth[w] > stat_simt_depth) stat_simt_depth = depth[w];
  end

  // workgroup lifetime
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active <= 1'b0; wg_done <= 1'b0; ctx_wg <= '0; ctx_arg <= '0; ctx_nw <= 3'd1;
    end else begin
      wg_done <= 1'b0;
      if (launch_valid) begin
        active <= 1'b1;
        ctx_wg <= launch_wg_id; ctx_arg <= launch_arg; ctx_nw <= launch_nwarps;
`ifdef BUG_WG_DONE_EARLY
      end else if (active && live == '0) begin
`else
      end else if (active && live == '0 && !lsu_busy && !sfu_busy) begin
`endif
        active <= 1'b0;
        wg_done <= 1'b1;
      end
    end
  end
endmodule
