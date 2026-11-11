// ALU of one sub-core: 8 lanes, one instruction per cycle, result registered (1 cycle latency).
//   ADD SUB MUL(low 32 bits) AND OR XOR, SHL/SHR (logical, amount = b[4:0]), SLT (signed: 1 or 0)
//   ADDI rd = a + imm, LUI rd = imm << 14
//   S2R rd = special register imm: 0 lane, 1 warp in workgroup, 2 workgroup id,
//            3 global thread id = (wg_id * nwarps + warp) * 8 + lane, 4 kernel argument base, other 0
//   BEQ/BNE: per lane, taken = (a == b) / (a != b); sent with JMP and EXIT to the SIMT stack (br_*)
// Results go to the register file through wb_* (valid/ready); only the lanes in the mask are written.
module alu
  import mgpu_pkg::*;
#(
  parameter int NW = 4,
  localparam int WW = $clog2(NW)
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             ex_valid,
  output logic             ex_ready,
  input  logic [WW-1:0]    ex_warp,
  input  logic [31:0]      ex_instr,
  input  logic [31:0]      ex_pc,
  input  logic [LANES-1:0] ex_mask,
  input  logic [31:0]      ex_a [LANES],
  input  logic [31:0]      ex_b [LANES],
  input  logic [31:0]      ctx_wg_id,      // context of ex_warp
  input  logic [2:0]       ctx_nwarps,
  input  logic [31:0]      ctx_arg,
  output logic             wb_valid,
  input  logic             wb_ready,
  output logic [WW-1:0]    wb_warp,
  output logic [3:0]       wb_rd,
  output logic [LANES-1:0] wb_mask,
  output logic [31:0]      wb_data [LANES],
  output logic             br_valid,
  output logic [WW-1:0]    br_warp,
  output logic [31:0]      br_instr,
  output logic [31:0]      br_pc,
  output logic [LANES-1:0] br_taken
);
  function automatic logic [31:0] op(logic [31:0] i, logic [31:0] a, logic [31:0] b, int lane,
                                     logic [WW-1:0] w, logic [31:0] wg, logic [2:0] nw, logic [31:0] arg);
    case (f_op(i))
      OP_ADD:  return a + b;
      OP_SUB:  return a - b;
      OP_MUL:  return a * b;
      OP_AND:  return a & b;
      OP_OR:   return a | b;
      OP_XOR:  return a ^ b;
`ifdef BUG_SHIFT_AMOUNT
      OP_SHL:  return a << b;
      OP_SHR:  return a >> b;
`else
      OP_SHL:  return a << b[4:0];
      OP_SHR:  return a >> b[4:0];
`endif
`ifdef BUG_SLT_UNSIGNED
      OP_SLT:  return {31'd0, a < b};
`else
      OP_SLT:  return {31'd0, $signed(a) < $signed(b)};
`endif
      OP_ADDI: return a + f_imm(i);
      OP_LUI:  return f_imm(i) << 14;
      OP_S2R:
        case (f_imm(i))
          0: return 32'(lane);
          1: return 32'(w);
`ifdef BUG_TID
          2: return wg;
          3: return (wg * 4 + 32'(w)) * LANES + 32'(lane);
`else
          2: return wg;
          3: return (wg * 32'(nw) + 32'(w)) * LANES + 32'(lane);
`endif
          4: return arg;
          default: return 32'd0;
        endcase
      default: return 32'd0;
    endcase
  endfunction

  logic is_br;
  assign is_br = unit_of(f_op(ex_instr)) == U_CTRL;
  assign ex_ready = !wb_valid || wb_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_valid <= 1'b0;
      br_valid <= 1'b0;
    end else begin
      br_valid <= 1'b0;
      if (wb_valid && wb_ready) wb_valid <= 1'b0;
      if (ex_valid && ex_ready) begin
        if (is_br) begin
          br_valid <= 1'b1;
          br_warp  <= ex_warp;
          br_instr <= ex_instr;
          br_pc    <= ex_pc;
          for (int l = 0; l < LANES; l++)
            br_taken[l] <= (f_op(ex_instr) == OP_BNE) ? (ex_a[l] != ex_b[l]) : (ex_a[l] == ex_b[l]);
        end else if (writes_rd(ex_instr)) begin
          wb_valid <= 1'b1;
          wb_warp  <= ex_warp;
          wb_rd    <= f_rd(ex_instr);
          wb_mask  <= ex_mask;
          for (int l = 0; l < LANES; l++)
            wb_data[l] <= op(ex_instr, ex_a[l], ex_b[l], l, ex_warp, ctx_wg_id, ctx_nwarps, ctx_arg);
        end
      end
    end
  end
endmodule
