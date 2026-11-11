// SIMT reconvergence stack: owns the pc and active mask of every warp of a sub-core.
// Each warp has a stack of entries {pc, mask, rpc}; the top entry is what the warp executes now.
//   advance      : top.pc += 4, then pop while top.pc == top.rpc (reached its reconvergence point)
//   JMP          : top.pc = branch pc + 4*target, then the same pop check
//   BEQ/BNE      : taken = lanes where the condition holds, among the active lanes
//                  all taken -> jump; none taken -> fall through;
//                  split -> top becomes the reconvergence entry (pc = join), push not-taken {pc+4},
//                           push taken {target}; both with rpc = join. Taken lanes run first.
//                           An entry whose pc is already the join is not pushed, and if the top entry already
//                           reconverges at the same join (divergent loop branch) it is replaced, not nested.
//   EXIT         : the active lanes leave every entry; entries left with no lanes are popped;
//                  an empty stack means the warp is finished (warp_exit pulse)
// Pushing beyond DEPTH entries sets the sticky overflow flag and the branch is executed as if uniform.
module simt_stack
  import mgpu_pkg::*;
#(
  parameter int NW    = 4,
  parameter int DEPTH = 7,
  localparam int WW = $clog2(NW),
  localparam int DW = $clog2(DEPTH + 1)
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [NW-1:0]    wl_mask,
  input  logic [31:0]      wl_pc,
  input  logic [NW-1:0]    adv_mask,
  input  logic             br_valid,
  input  logic [WW-1:0]    br_warp,
  input  logic [31:0]      br_instr,
  input  logic [31:0]      br_pc,
  input  logic [LANES-1:0] br_taken,
  output logic [31:0]      pc   [NW],
  output logic [LANES-1:0] mask [NW],
  output logic [NW-1:0]    live,
  output logic [NW-1:0]    ctrl_done,
  output logic [NW-1:0]    warp_exit,
  output logic             overflow,
  output logic [DW-1:0]    depth [NW]
);
  logic [31:0]      e_pc   [NW][DEPTH];
  logic [LANES-1:0] e_mask [NW][DEPTH];
  logic [31:0]      e_rpc  [NW][DEPTH];
  logic [DW-1:0]    sp     [NW];

  always_comb
    for (int w = 0; w < NW; w++) begin
      live[w]  = (sp[w] != 0);
      pc[w]    = (sp[w] != 0) ? e_pc[w][sp[w] - 1]   : 32'd0;
      mask[w]  = (sp[w] != 0) ? e_mask[w][sp[w] - 1] : '0;
      depth[w] = sp[w];
    end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int w = 0; w < NW; w++) sp[w] <= '0;
      ctrl_done <= '0;
      warp_exit <= '0;
      overflow  <= 1'b0;
    end else begin
      ctrl_done <= '0;
      warp_exit <= '0;
      for (int w = 0; w < NW; w++) begin
        // working copies of this warp's stack
        logic [31:0]      p   [DEPTH];
        logic [LANES-1:0] m   [DEPTH];
        logic [31:0]      r   [DEPTH];
        logic [DW-1:0]    s;
        logic             touched;
        for (int k = 0; k < DEPTH; k++) begin p[k] = e_pc[w][k]; m[k] = e_mask[w][k]; r[k] = e_rpc[w][k]; end
        s = sp[w];
        touched = 1'b0;

        if (wl_mask[w]) begin
          s = 1; p[0] = wl_pc; m[0] = '1; r[0] = 32'hFFFF_FFFF;
        end else if (s != 0 && adv_mask[w]) begin
          p[s - 1] = p[s - 1] + 4;
          touched = 1'b1;
        end else if (s != 0 && br_valid && br_warp == w) begin
          logic [LANES-1:0] act, tk;
          logic [31:0]      tgt, fall, jn;
          act  = m[s - 1];
          tgt  = br_pc + (f_target(br_instr) << 2);
          fall = br_pc + 4;
          jn   = br_pc + (f_join(br_instr) << 2);
          tk   = br_taken & act;
          ctrl_done[w] <= 1'b1;
          touched = 1'b1;
          case (f_op(br_instr))
            OP_JMP: p[s - 1] = tgt;
            OP_EXIT: begin
`ifdef BUG_EXIT_MASK
              m[s - 1] = '0;
`else
              for (int k = 0; k < DEPTH; k++) m[k] = m[k] & ~act;
`endif
              for (int k = 0; k < DEPTH; k++) if (s != 0 && m[s - 1] == '0) s = s - 1;
              if (s == 0) warp_exit[w] <= 1'b1;
            end
            default: begin   // BEQ / BNE
              if (tk == act) p[s - 1] = tgt;
              else if (tk == '0) p[s - 1] = fall;
              else begin
                // split. An entry whose pc already equals the join would only reconverge at once: not pushed.
                // If the top entry already reconverges at this join (a divergent loop branch), it is replaced
                // instead of nested, so a loop never grows the stack.
                logic need_fall, need_tgt, reuse;
                logic [DW:0] after;
                need_fall = (fall != jn);
                need_tgt  = (tgt != jn);
                reuse     = (r[s - 1] == jn);
                after     = (DW+1)'(s) - (reuse ? 1 : 0) + need_fall + need_tgt;
                if (after > DEPTH) begin
                  overflow <= 1'b1;
                  p[s - 1] = tgt;
                end else begin
                  if (reuse) s = s - 1;
                  else p[s - 1] = jn;
`ifdef BUG_PUSH_ORDER
                  if (need_tgt)  begin p[s] = tgt;  m[s] = tk;        r[s] = jn; s = s + 1; end
                  if (need_fall) begin p[s] = fall; m[s] = act & ~tk; r[s] = jn; s = s + 1; end
`else
                  if (need_fall) begin p[s] = fall; m[s] = act & ~tk; r[s] = jn; s = s + 1; end
                  if (need_tgt)  begin p[s] = tgt;  m[s] = tk;        r[s] = jn; s = s + 1; end
`endif
                end
              end
            end
          endcase
        end
`ifndef BUG_NO_POP
        // reconvergence: pop every top entry that has reached its rpc (nested joins can coincide)
        if (touched)
          for (int k = 0; k < DEPTH; k++) if (s != 0 && p[s - 1] == r[s - 1]) s = s - 1;
`endif
        for (int k = 0; k < DEPTH; k++) begin e_pc[w][k] <= p[k]; e_mask[w][k] <= m[k]; e_rpc[w][k] <= r[k]; end
        sp[w] <= s;
      end
    end
  end
endmodule
