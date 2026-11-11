typedef virtual ws_interface ws_vif_t;
import mgpu_pkg::*;

class ws_config extends uvm_object;
  `uvm_object_utils(ws_config)
  int issue_rdy_pct = 80;    // operand collector readiness
  int fetch_rdy_pct = 80;
  int fetch_max_lat = 4;
  int alu_lat = 2, sfu_max_lat = 30, lsu_max_lat = 15;
  int reg_span = 6;          // instructions use registers 0..reg_span-1 (small span = many hazards)
  int ctrl_pct = 8;
  int exit_pct = 25;         // of control instructions, how many are EXIT
  int ctrl_max_lat = 6;
  bit stop = 0;              // no more relaunches (end of test)
  function new(string name = "ws_config");
    super.new(name);
  endfunction
endclass

// The program: the instruction at any pc is a fixed pseudo-random function of the pc and the program seed,
// so the checker can always recompute what must be issued.
class ws_program extends uvm_object;
  `uvm_object_utils(ws_program)
  int seed = 1;
  ws_config cfg;
  function new(string name = "ws_program");
    super.new(name);
  endfunction
  function bit [31:0] hash(bit [31:0] x);
    x = x ^ (x >> 16); x = x * 32'h7feb352d; x = x ^ (x >> 15); x = x * 32'h846ca68b; x = x ^ (x >> 16);
    return x;
  endfunction
  function bit [31:0] instr(bit [31:0] pc);
    bit [31:0] h = hash(pc ^ (seed * 32'h9E3779B9));
    int r = h % 100;
    bit [5:0] op;
    bit [3:0] rd = (h >> 8) % cfg.reg_span, rs1 = (h >> 12) % cfg.reg_span, rs2 = (h >> 16) % cfg.reg_span;
    if (r < cfg.ctrl_pct) begin
      int c = (h >> 20) % 100;
      op = (c < cfg.exit_pct) ? OP_EXIT : (c < 50) ? OP_BEQ : (c < 75) ? OP_JMP : OP_BNE;
    end else if (r < cfg.ctrl_pct + 6) op = OP_DIV;
    else if (r < cfg.ctrl_pct + 16) op = ((h >> 20) & 1) ? OP_LD : OP_ST;
    else if (r < cfg.ctrl_pct + 20) op = OP_NOP;
    else if (r < cfg.ctrl_pct + 25) op = OP_S2R;
    else op = 6'((h >> 24) % 10 + 1);   // ADD .. ADDI
    return {op, rd, rs1, rs2, 14'(h >> 4)};
  endfunction
endclass
