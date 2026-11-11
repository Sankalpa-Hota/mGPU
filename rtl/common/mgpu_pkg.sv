// mGPU shared definitions: sizes, ISA opcodes, instruction field helpers.
package mgpu_pkg;
  localparam int LANES   = 8;    // threads per warp
  localparam int NWARP   = 4;    // warp slots per sub-core
  localparam int NSUB    = 2;    // sub-cores per SM
  localparam int NSM     = 2;    // SMs
  localparam int NREG    = 16;   // registers per thread
  localparam int NSLOT   = NSM * NSUB;  // workgroup slots in the chip (one workgroup per sub-core)

  // opcodes [31:26]
  localparam logic [5:0] OP_NOP   = 6'h00, OP_ADD  = 6'h01, OP_SUB  = 6'h02, OP_MUL  = 6'h03,
                         OP_AND   = 6'h04, OP_OR   = 6'h05, OP_XOR  = 6'h06, OP_SHL  = 6'h07,
                         OP_SHR   = 6'h08, OP_SLT  = 6'h09, OP_ADDI = 6'h0A, OP_LUI  = 6'h0B,
                         OP_S2R   = 6'h0C, OP_DIV  = 6'h10, OP_REM  = 6'h11, OP_ISQRT = 6'h12,
                         OP_LD    = 6'h18, OP_ST   = 6'h19, OP_LDS  = 6'h1A, OP_STS  = 6'h1B,
                         OP_BEQ   = 6'h20, OP_BNE  = 6'h21, OP_JMP  = 6'h22, OP_BAR  = 6'h23,
                         OP_EXIT  = 6'h3F;

  // execution unit classes
  typedef enum logic [2:0] {U_ALU, U_SFU, U_LSU, U_CTRL, U_NONE} unit_e;

  function automatic logic [5:0] f_op(logic [31:0] i);  return i[31:26]; endfunction
  function automatic logic [3:0] f_rd(logic [31:0] i);  return i[25:22]; endfunction
  function automatic logic [3:0] f_rs1(logic [31:0] i); return i[21:18]; endfunction
  function automatic logic [3:0] f_rs2(logic [31:0] i); return i[17:14]; endfunction
  function automatic logic [31:0] f_imm(logic [31:0] i); return {{14{i[17]}}, i[17:0]}; endfunction
  function automatic logic [31:0] f_target(logic [31:0] i); return {{23{i[17]}}, i[17:9]}; endfunction  // instructions
  function automatic logic [31:0] f_join(logic [31:0] i);   return {23'd0, i[8:0]}; endfunction          // instructions

  function automatic unit_e unit_of(logic [5:0] op);
    case (op)
      OP_DIV, OP_REM, OP_ISQRT:            return U_SFU;
      OP_LD, OP_ST, OP_LDS, OP_STS:        return U_LSU;
      OP_BEQ, OP_BNE, OP_JMP, OP_BAR, OP_EXIT: return U_CTRL;
      OP_NOP:                              return U_NONE;
      default:                             return U_ALU;
    endcase
  endfunction

  // does this instruction write rd?
  function automatic logic writes_rd(logic [31:0] i);
    case (f_op(i))
      OP_ADD, OP_SUB, OP_MUL, OP_AND, OP_OR, OP_XOR, OP_SHL, OP_SHR, OP_SLT, OP_ADDI, OP_LUI, OP_S2R,
      OP_DIV, OP_REM, OP_ISQRT, OP_LD, OP_LDS: return f_rd(i) != 0;
      default: return 1'b0;
    endcase
  endfunction

  // operand B: rs2 for R-type, rd for stores and branches (data / second compare value)
  function automatic logic [3:0] src_b(logic [31:0] i);
    case (f_op(i))
      OP_ST, OP_STS, OP_BEQ, OP_BNE: return f_rd(i);
      default: return f_rs2(i);
    endcase
  endfunction
  function automatic logic uses_b(logic [31:0] i);
    case (f_op(i))
      OP_ADD, OP_SUB, OP_MUL, OP_AND, OP_OR, OP_XOR, OP_SHL, OP_SHR, OP_SLT, OP_DIV, OP_REM,
      OP_ST, OP_STS, OP_BEQ, OP_BNE: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction
  function automatic logic uses_a(logic [31:0] i);
    case (f_op(i))
      OP_NOP, OP_LUI, OP_S2R, OP_JMP, OP_BAR, OP_EXIT: return 1'b0;
      default: return 1'b1;
    endcase
  endfunction
endpackage
