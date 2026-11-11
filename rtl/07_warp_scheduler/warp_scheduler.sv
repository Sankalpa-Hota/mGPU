// Warp scheduler of one sub-core.
//  - keeps a one-entry instruction buffer per warp and fetches into it (one fetch in flight, round-robin)
//  - keeps a scoreboard per warp: one pending bit per register that an issued instruction will still write
//  - issues one instruction per cycle from a warp whose buffered instruction has no hazard (round-robin)
//      RAW: a source register is pending   WAW: the destination is pending
//  - control instructions (branches, JMP, BAR, EXIT) stop that warp until ctrl_done says the new pc is known
//  - EXIT is held until the warp has no pending register writes
// The PC and liveness of every warp belong to the SIMT stack (block 08); this block reads them.
module warp_scheduler
  import mgpu_pkg::*;
#(
  parameter int NW  = 4,
  parameter int NWB = 3,
  localparam int WW = $clog2(NW)
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic [NW-1:0]   wl_mask,          // warps (re)launched this cycle
  input  logic [NW-1:0]   live,
  input  logic [31:0]     pc [NW],
  output logic            f_valid,
  input  logic            f_ready,
  output logic [31:0]     f_pc,
  input  logic            f_rsp_valid,
  input  logic [31:0]     f_rsp_instr,
  output logic            is_valid,
  input  logic            is_ready,
  output logic [WW-1:0]   is_warp,
  output logic [31:0]     is_instr,
  output logic [31:0]     is_pc,
  output logic [NW-1:0]   adv_mask,         // non-control instruction issued: SIMT moves pc forward
  input  logic [NWB-1:0]  wb_valid,         // a register was written: clear its pending bit
  input  logic [WW-1:0]   wb_warp [NWB],
  input  logic [3:0]      wb_rd   [NWB],
  input  logic [NW-1:0]   ctrl_done,        // control instruction resolved
  output logic [NW-1:0]   elig,             // debug: warps that could issue this cycle
  output logic            idle              // nothing buffered, fetching or waiting
);
  logic [NW-1:0]  ibuf_v, ctrl_wait;
  logic [31:0]    ibuf_instr [NW];
  logic [31:0]    ibuf_pc    [NW];
  logic [NREG-1:0] pend [NW];
  logic           f_busy;
  logic           f_stale;   // the warp being fetched died or was relaunched: drop the answer
  logic [WW-1:0]  f_warp, f_rr, i_rr, i_sel_q, f_sel_q;
  logic           i_hold, f_hold;

  // ---------------- fetch
  logic          f_any;
  logic [WW-1:0] f_pick;
  always_comb begin
    f_any = 1'b0;
    f_pick = '0;
    for (int k = NW - 1; k >= 0; k--) begin
      logic [WW-1:0] w;
      w = WW'(f_rr + k);
      if (live[w] && !ibuf_v[w] && !ctrl_wait[w] && !wl_mask[w]) begin f_any = 1'b1; f_pick = w; end
    end
  end
  // a fetch request, once offered, is held for the same warp until accepted (valid/ready rule)
  logic [WW-1:0] f_sel;
`ifdef BUG_NO_HOLD
  assign f_sel   = f_pick;
  assign f_valid = !f_busy && f_any;
`else
  assign f_sel   = f_hold ? f_sel_q : f_pick;
  assign f_valid = f_hold || (!f_busy && f_any);
`endif
  assign f_pc    = pc[f_sel];

  // ---------------- hazards and issue
  function automatic logic hazard(logic [31:0] i, logic [NREG-1:0] p);
    hazard = (uses_a(i) && p[f_rs1(i)]) || (uses_b(i) && p[src_b(i)]);
`ifndef BUG_NO_WAW
    hazard = hazard || (writes_rd(i) && p[f_rd(i)]);
`endif
    // EXIT waits for every outstanding write of the warp, so no late writeback can reach a relaunched warp
    if (f_op(i) == OP_EXIT) hazard = hazard || (p != '0);
  endfunction

  always_comb
    for (int w = 0; w < NW; w++)
      elig[w] = live[w] && ibuf_v[w] && !ctrl_wait[w] && !hazard(ibuf_instr[w], pend[w]);

  logic          i_any;
  logic [WW-1:0] i_pick, i_sel;
  always_comb begin
    i_any = 1'b0;
    i_pick = '0;
    for (int k = NW - 1; k >= 0; k--) begin
      logic [WW-1:0] w;
      w = WW'(i_rr + k);
      if (elig[w]) begin i_any = 1'b1; i_pick = w; end
    end
  end
`ifdef BUG_NO_HOLD
  assign i_sel    = i_pick;
  assign is_valid = i_any;
`else
  assign i_sel    = i_hold ? i_sel_q : i_pick;
  assign is_valid = i_hold || i_any;
`endif
  assign is_warp  = i_sel;
  assign is_instr = ibuf_instr[i_sel];
  assign is_pc    = ibuf_pc[i_sel];

  logic issue;
  assign issue = is_valid && is_ready;
  always_comb begin
    adv_mask = '0;
    if (issue && unit_of(f_op(is_instr)) != U_CTRL) adv_mask[i_sel] = 1'b1;
  end

  assign idle = (ibuf_v & live) == 0 && !f_busy && (ctrl_wait & live) == 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ibuf_v <= '0; ctrl_wait <= '0; f_busy <= 1'b0; f_stale <= 1'b0; f_warp <= '0; f_rr <= '0; i_rr <= '0;
      i_hold <= 1'b0; i_sel_q <= '0; f_hold <= 1'b0; f_sel_q <= '0;
      for (int w = 0; w < NW; w++) pend[w] <= '0;
    end else begin
      // fetch handshake and response
      f_hold  <= f_valid && !f_ready;
      f_sel_q <= f_sel;
      if (f_valid && f_ready) begin
        f_busy  <= 1'b1;
        f_stale <= f_hold && (wl_mask[f_sel] || !live[f_sel]);
        f_warp  <= f_sel;
        f_rr    <= WW'(f_sel + 1);
      end
      if (f_busy && (wl_mask[f_warp] || !live[f_warp])) f_stale <= 1'b1;
      if (f_rsp_valid) begin
        f_busy <= 1'b0;
        ibuf_v[f_warp]     <= !f_stale && !wl_mask[f_warp] && live[f_warp];
        ibuf_instr[f_warp] <= f_rsp_instr;
        ibuf_pc[f_warp]    <= pc[f_warp];
      end
      // issue
      i_hold  <= is_valid && !is_ready;
      i_sel_q <= i_sel;
      if (issue) begin
        ibuf_v[i_sel] <= 1'b0;
`ifndef BUG_RR_STUCK
        i_rr <= WW'(i_sel + 1);
`endif
      end
      // scoreboard: clear on writeback, set on issue (set wins for the same register)
      for (int w = 0; w < NW; w++) begin
        logic [NREG-1:0] p;
        p = pend[w];
        for (int k = 0; k < NWB; k++) if (wb_valid[k] && wb_warp[k] == w) p[wb_rd[k]] = 1'b0;
        if (issue && i_sel == w && writes_rd(is_instr)) p[f_rd(is_instr)] = 1'b1;
        pend[w] <= p;
      end
      ctrl_wait <= (issue && unit_of(f_op(is_instr)) == U_CTRL ? (ctrl_wait | (NW'(1) << i_sel)) : ctrl_wait) & ~ctrl_done;
      // dead or relaunched warps lose their state
      for (int w = 0; w < NW; w++)
        if (wl_mask[w] || !live[w]) begin
          ibuf_v[w] <= 1'b0;
          ctrl_wait[w] <= 1'b0;
          if (wl_mask[w]) pend[w] <= '0;
        end
    end
  end
endmodule
