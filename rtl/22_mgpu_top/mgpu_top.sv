// mGPU: the complete GPU.
//   CPU --APB--> RBBM; CP (ring fetch -> packet decoder -> SQE); dispatcher; 2 SMs; GMU;
//   SMs --crossbar--> 2 L2 banks; L2 banks + CP fetch + SQE fences --arbiter--> MMU --> GBIF --AXI4--> DRAM.
// The command ring and the fences take the uncached path (they bypass the L2): the CPU writes the ring and
// reads the fences directly in DRAM, so a cached copy could be stale.
//
// Control registers written by type 4 packets (in order with the other commands, see SQE):
//   0x100-0x102 dispatcher (kernel pc, warps per workgroup, argument base)
//   0x200 PTBR   0x201 MMU_ENABLE   0x202 TLB_INVALIDATE (any write)   0x203 L2_FLUSH (clean + invalidate)
//   0x204 GMU_IDLE_LIMIT            0x205 MMU_FAULT_CLEAR (any write)
// Busy bits (for WAIT_FOR_IDLE and the RBBM): 0 dispatcher + SMs, 1 L2 (incl. flush), 2 path below the L2,
//   3 command fetch.
module mgpu_top
  import mgpu_pkg::*;
(
  input  logic         clk,
  input  logic         rst_n,
  // CPU register port
  input  logic         psel,
  input  logic         penable,
  input  logic         pwrite,
  input  logic [11:0]  paddr,
  input  logic [31:0]  pwdata,
  output logic [31:0]  prdata,
  output logic         pready,
  output logic         pslverr,
  output logic         irq,
  output logic         mmu_fault,
  output logic [31:0]  mmu_fault_va,
  // AXI4 master toward DRAM
  output logic [31:0]  araddr,
  output logic [7:0]   arlen,
  output logic [2:0]   arsize,
  output logic [1:0]   arburst,
  output logic         arvalid,
  input  logic         arready,
  input  logic [31:0]  rdata,
  input  logic [1:0]   rresp,
  input  logic         rlast,
  input  logic         rvalid,
  output logic         rready,
  output logic [31:0]  awaddr,
  output logic [7:0]   awlen,
  output logic [2:0]   awsize,
  output logic [1:0]   awburst,
  output logic         awvalid,
  input  logic         awready,
  output logic [31:0]  wdata,
  output logic [3:0]   wstrb,
  output logic         wlast,
  output logic         wvalid,
  input  logic         wready,
  input  logic [1:0]   bresp,
  input  logic         bvalid,
  output logic         bready,
  input  logic [15:0]  dram_perf    // [0] row hit, [1] row miss (from the DRAM controller, for the perf counters)
);
  // ---------------------------------------------------------------- reset: soft reset clears everything but RBBM
  logic soft_reset, core_rst_n;
  assign core_rst_n = rst_n && !soft_reset;

  // ---------------------------------------------------------------- RBBM
  logic [31:0] ring_base;
  logic [9:0]  ring_wptr, ring_rptr;
  logic [7:0]  busy_bits;
  logic [15:0] perf_ev;
  logic        progress, sqe_irq, bad_pkt, bad_op;
  rbbm #(.RING_LOG2(10), .NBUSY(8), .NEV(16)) u_rbbm (
    .clk(clk), .rst_n(rst_n), .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr), .ring_base(ring_base), .ring_wptr(ring_wptr), .ring_rptr(ring_rptr),
    .ev_fence(sqe_irq), .ev_bad_pkt(bad_pkt), .ev_bad_op(bad_op), .busy_in(busy_bits), .progress(progress),
    .perf_ev(perf_ev), .irq(irq), .soft_reset(soft_reset));

  // ---------------------------------------------------------------- CP: ring fetch, decoder, SQE
  logic         rf_mreq_valid, rf_mreq_ready, rf_mrsp_valid, rf_busy;
  logic [31:0]  rf_mreq_addr;
  logic         dw_valid, dw_ready;
  logic [31:0]  dw_data;
  logic [255:0] below_rsp_data;
  cp_ring_fetch #(.RING_LOG2(10), .FIFO_DEPTH(16)) u_fetch (
    .clk(clk), .rst_n(core_rst_n), .ring_base(ring_base), .wptr(ring_wptr), .rptr(ring_rptr),
    .mreq_valid(rf_mreq_valid), .mreq_ready(rf_mreq_ready), .mreq_addr(rf_mreq_addr), .mrsp_valid(rf_mrsp_valid),
    .mrsp_data(below_rsp_data), .dw_valid(dw_valid), .dw_ready(dw_ready), .dw_data(dw_data), .busy(rf_busy));

  logic        reg_wr_en, op_valid, op_last, dec_busy, sqe_op_ready;
  logic [17:0] reg_wr_addr;
  logic [31:0] reg_wr_data, op_data;
  logic [6:0]  op_code;
  cp_packet_decoder u_dec (
    .clk(clk), .rst_n(core_rst_n), .dw_valid(dw_valid), .dw_ready(dw_ready), .dw_data(dw_data),
    .out_ready(sqe_op_ready),                     // register writes also wait: they stay in order with operations
    .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .op_valid(op_valid), .op_code(op_code), .op_data(op_data), .op_last(op_last), .bad_pkt(bad_pkt), .busy(dec_busy));

  logic         disp_valid, disp_ready, sqe_busy, op_done;
  logic [31:0]  disp_num_wg;
  logic         sq_mreq_valid, sq_mreq_ready, sq_mreq_we, sq_mrsp_valid;
  logic [31:0]  sq_mreq_addr, sq_mreq_wstrb;
  logic [255:0] sq_mreq_wdata;
  cp_sqe #(.NBUSY(8), .SETTLE(3)) u_sqe (
    .clk(clk), .rst_n(core_rst_n), .op_valid(op_valid), .op_ready(sqe_op_ready), .op_code(op_code), .op_data(op_data),
    .op_last(op_last), .disp_valid(disp_valid), .disp_ready(disp_ready), .disp_num_wg(disp_num_wg), .busy_in(busy_bits),
    .mreq_valid(sq_mreq_valid), .mreq_ready(sq_mreq_ready), .mreq_addr(sq_mreq_addr), .mreq_we(sq_mreq_we),
    .mreq_wdata(sq_mreq_wdata), .mreq_wstrb(sq_mreq_wstrb), .mrsp_valid(sq_mrsp_valid),
    .irq(sqe_irq), .op_done(op_done), .bad_op(bad_op), .busy(sqe_busy));

  // ---------------------------------------------------------------- control registers
  logic [31:0] ptbr;
  logic        mmu_en, tlb_inv, fault_clear;
  logic [15:0] idle_limit;
  logic [1:0]  flush_pend, flush_done;
  always_ff @(posedge clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      ptbr <= '0; mmu_en <= 1'b0; tlb_inv <= 1'b0; fault_clear <= 1'b0; idle_limit <= '0; flush_pend <= '0;
    end else begin
      tlb_inv <= 1'b0; fault_clear <= 1'b0;
      flush_pend <= flush_pend & ~flush_done;
      if (reg_wr_en) case (reg_wr_addr)
        18'h200: ptbr <= reg_wr_data;
        18'h201: mmu_en <= reg_wr_data[0];
        18'h202: tlb_inv <= 1'b1;
        18'h203: flush_pend <= 2'b11;
        18'h204: idle_limit <= reg_wr_data[15:0];
        18'h205: fault_clear <= 1'b1;
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------- dispatcher, GMU, SMs
  logic         launch_valid, disp_busy;
  logic [1:0]   launch_slot;
  logic [31:0]  launch_wg_id, launch_pc, launch_arg;
  logic [2:0]   launch_nwarps;
  logic [3:0]   wg_done;
  logic [1:0]   sm_avail, sm_want, sm_busy, sm_power, gmu_off, gmu_wake;
  dispatcher #(.NSM(2), .NSUB(2)) u_disp (
    .clk(clk), .rst_n(core_rst_n), .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .disp_valid(disp_valid), .disp_ready(disp_ready), .disp_num_wg(disp_num_wg),
    .launch_valid(launch_valid), .launch_slot(launch_slot), .launch_wg_id(launch_wg_id), .launch_nwarps(launch_nwarps),
    .launch_pc(launch_pc), .launch_arg(launch_arg), .wg_done(wg_done), .sm_avail(sm_avail), .sm_want(sm_want), .busy(disp_busy));

  gmu #(.NSM(2), .WAKE_CYCLES(6)) u_gmu (
    .clk(clk), .rst_n(core_rst_n), .idle_limit(idle_limit), .sm_busy(sm_busy), .sm_want(sm_want), .sm_avail(sm_avail),
    .sm_power(sm_power), .stat_off_pulse(gmu_off), .stat_wake_pulse(gmu_wake));

  logic         kernel_start;
  assign kernel_start = disp_valid && disp_ready;     // new kernel: SM instruction caches and L1s are invalidated

  logic [1:0]   s_mreq_valid, s_mreq_ready, s_mrsp_valid, s_l1hit, s_ovf;
  logic [31:0]  s_mreq_addr  [2];
  logic         s_mreq_we    [2];
  logic [255:0] s_mreq_wdata [2];
  logic [31:0]  s_mreq_wstrb [2];
  logic [255:0] s_mrsp_data  [2];
  logic [1:0]   s_issue [2];
  logic [1:0]   s_wg_done [2];
  for (genvar m = 0; m < 2; m++) begin : g_sm
    sm u_sm (
      .clk(clk), .rst_n(core_rst_n), .launch_valid(launch_valid && launch_slot[0] == m), .launch_sub(launch_slot[1]),
      .launch_wg_id(launch_wg_id), .launch_nwarps(launch_nwarps), .launch_pc(launch_pc), .launch_arg(launch_arg),
      .wg_done(s_wg_done[m]), .busy(sm_busy[m]), .invalidate(kernel_start),
      .mreq_valid(s_mreq_valid[m]), .mreq_ready(s_mreq_ready[m]), .mreq_addr(s_mreq_addr[m]), .mreq_we(s_mreq_we[m]),
      .mreq_wdata(s_mreq_wdata[m]), .mreq_wstrb(s_mreq_wstrb[m]), .mrsp_valid(s_mrsp_valid[m]), .mrsp_data(s_mrsp_data[m]),
      .stat_issue(s_issue[m]), .stat_l1_hit_pulse(s_l1hit[m]), .stat_overflow(s_ovf[m]));
  end
  // slot s = SM (s % 2), sub-core (s / 2)
  assign wg_done = {s_wg_done[1][1], s_wg_done[0][1], s_wg_done[1][0], s_wg_done[0][0]};

  // ---------------------------------------------------------------- crossbar -> L2 banks
  logic [1:0]   b_valid, b_ready, b_rsp_valid;
  logic [31:0]  b_addr  [2];
  logic         b_we    [2];
  logic [255:0] b_wdata [2];
  logic [31:0]  b_wstrb [2];
  logic [0:0]   b_id    [2];
  logic [255:0] b_rsp_data [2];
  logic [0:0]   b_rsp_id   [2];
  crossbar #(.N(2), .NB(2)) u_xbar (
    .clk(clk), .rst_n(core_rst_n), .req_valid(s_mreq_valid), .req_ready(s_mreq_ready), .req_addr(s_mreq_addr),
    .req_we(s_mreq_we), .req_wdata(s_mreq_wdata), .req_wstrb(s_mreq_wstrb), .rsp_valid(s_mrsp_valid), .rsp_data(s_mrsp_data),
    .b_valid(b_valid), .b_ready(b_ready), .b_addr(b_addr), .b_we(b_we), .b_wdata(b_wdata), .b_wstrb(b_wstrb), .b_id(b_id),
    .b_rsp_valid(b_rsp_valid), .b_rsp_data(b_rsp_data), .b_rsp_id(b_rsp_id));

  logic [1:0]   l2_mreq_valid, l2_mreq_ready, l2_mrsp_valid, l2_busy;
  logic [31:0]  l2_mreq_addr  [2];
  logic         l2_mreq_we    [2];
  logic [255:0] l2_mreq_wdata [2];
  logic         below_rsp_err;
  for (genvar b = 0; b < 2; b++) begin : g_l2
    l2_cache #(.SETS(32), .NB(2), .IDW(1), .BANK(b)) u_l2 (
      .clk(clk), .rst_n(core_rst_n), .req_valid(b_valid[b]), .req_ready(b_ready[b]), .req_addr(b_addr[b]), .req_we(b_we[b]),
      .req_wdata(b_wdata[b]), .req_wstrb(b_wstrb[b]), .req_id(b_id[b]), .rsp_valid(b_rsp_valid[b]), .rsp_data(b_rsp_data[b]),
      .rsp_id(b_rsp_id[b]), .flush_req(flush_pend[b]), .flush_done(flush_done[b]),
      .mreq_valid(l2_mreq_valid[b]), .mreq_ready(l2_mreq_ready[b]), .mreq_addr(l2_mreq_addr[b]), .mreq_we(l2_mreq_we[b]),
      .mreq_wdata(l2_mreq_wdata[b]), .mrsp_valid(l2_mrsp_valid[b]), .mrsp_data(below_rsp_data), .mrsp_err(below_rsp_err),
      .busy(l2_busy[b]));
  end

  // ---------------------------------------------------------------- below the L2: 4 requesters -> MMU
  logic [3:0]   a_valid, a_ready, a_rsp_valid;
  logic [31:0]  a_addr  [4];
  logic         a_we    [4];
  logic [255:0] a_wdata [4];
  logic [31:0]  a_wstrb [4];
  assign a_valid = {sq_mreq_valid, rf_mreq_valid, l2_mreq_valid[1], l2_mreq_valid[0]};
  assign a_addr  = '{l2_mreq_addr[0], l2_mreq_addr[1], rf_mreq_addr, sq_mreq_addr};
  assign a_we    = '{l2_mreq_we[0], l2_mreq_we[1], 1'b0, sq_mreq_we};
  assign a_wdata = '{l2_mreq_wdata[0], l2_mreq_wdata[1], 256'd0, sq_mreq_wdata};
  assign a_wstrb = '{32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'd0, sq_mreq_wstrb};
  assign l2_mreq_ready = a_ready[1:0];
  assign rf_mreq_ready = a_ready[2];
  assign sq_mreq_ready = a_ready[3];
  assign l2_mrsp_valid = a_rsp_valid[1:0];
  assign rf_mrsp_valid = a_rsp_valid[2];
  assign sq_mrsp_valid = a_rsp_valid[3];

  logic         m_req_valid, m_req_ready, m_req_we, m_rsp_valid;
  logic [31:0]  m_req_addr, m_req_wstrb;
  logic [255:0] m_req_wdata;
  line_arbiter #(.N(4)) u_below_arb (
    .clk(clk), .rst_n(core_rst_n), .in_valid(a_valid), .in_ready(a_ready), .in_addr(a_addr), .in_we(a_we),
    .in_wdata(a_wdata), .in_wstrb(a_wstrb), .in_rsp_valid(a_rsp_valid), .in_rsp_data(below_rsp_data),
    .out_valid(m_req_valid), .out_ready(m_req_ready), .out_addr(m_req_addr), .out_we(m_req_we), .out_wdata(m_req_wdata),
    .out_wstrb(m_req_wstrb), .out_rsp_valid(m_rsp_valid), .out_rsp_data(mmu_rsp_data));

  logic         g_req_valid, g_req_ready, g_req_we, g_rsp_valid, g_rsp_err, tlb_hit, walk, fault_write;
  logic [31:0]  g_req_addr, g_req_wstrb;
  logic [255:0] g_req_wdata, g_rsp_data, mmu_rsp_data;
  mmu #(.TLB_N(8)) u_mmu (
    .clk(clk), .rst_n(core_rst_n), .enable(mmu_en), .ptbr(ptbr), .tlb_invalidate(tlb_inv),
    .req_valid(m_req_valid), .req_ready(m_req_ready), .req_addr(m_req_addr), .req_we(m_req_we), .req_wdata(m_req_wdata),
    .req_wstrb(m_req_wstrb), .rsp_valid(m_rsp_valid), .rsp_data(mmu_rsp_data), .rsp_err(below_rsp_err),
    .mreq_valid(g_req_valid), .mreq_ready(g_req_ready), .mreq_addr(g_req_addr), .mreq_we(g_req_we), .mreq_wdata(g_req_wdata),
    .mreq_wstrb(g_req_wstrb), .mrsp_valid(g_rsp_valid), .mrsp_data(g_rsp_data),
    .fault_valid(mmu_fault), .fault_va(mmu_fault_va), .fault_write(fault_write), .fault_clear(fault_clear),
    .stat_tlb_hit(tlb_hit), .stat_walk(walk));

  gbif u_gbif (
    .clk(clk), .rst_n(core_rst_n), .req_valid(g_req_valid), .req_ready(g_req_ready), .req_addr(g_req_addr), .req_we(g_req_we),
    .req_wdata(g_req_wdata), .req_wstrb(g_req_wstrb), .rsp_valid(g_rsp_valid), .rsp_data(g_rsp_data), .rsp_err(g_rsp_err),
    .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready));

  // ---------------------------------------------------------------- busy, progress, performance events
  // bit 2 counts only L2 traffic below the L2: the command fetch must not wait for itself (WAIT_FOR_IDLE is a command)
  assign busy_bits = {4'd0, rf_busy || dec_busy, (a_valid[1:0] != 0) || (a_rsp_valid[1:0] != 0) || (u_below_arb.busy && u_below_arb.owner < 2), (|l2_busy) || (|flush_pend), disp_busy};
  assign progress  = op_done || (dw_valid && dw_ready) || (|s_issue[0]) || (|s_issue[1]);
  assign perf_ev   = {3'd0, dw_valid && dw_ready, |gmu_wake, |gmu_off, launch_valid, op_done, dram_perf[1], dram_perf[0],
                      walk, tlb_hit, s_l1hit[1], s_l1hit[0], |s_issue[1], |s_issue[0]};
endmodule
