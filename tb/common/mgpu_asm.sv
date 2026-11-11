// A tiny assembler for the mGPU ISA. Instructions are appended in order; branches name labels, which are
// resolved by finish(). Used by the SM and full-chip testbenches to write kernels.
class mgpu_asm;
  bit [31:0] code[$];
  int        labels[string];
  typedef struct { int at; string target; string join_l; } fix_t;
  fix_t fixes[$];
  string name;

  function new(string name = "kernel"); this.name = name; endfunction

  function void emit(bit [31:0] w);  code.push_back(w); endfunction
  function void label(string l);     labels[l] = code.size(); endfunction

  function void r(bit [5:0] op, int rd, int rs1, int rs2); emit({op, 4'(rd), 4'(rs1), 4'(rs2), 14'd0}); endfunction
  function void i(bit [5:0] op, int rd, int rs1, int imm); emit({op, 4'(rd), 4'(rs1), 18'(imm)}); endfunction
  function void add(int rd, int a, int b);  r(6'h01, rd, a, b); endfunction
  function void sub(int rd, int a, int b);  r(6'h02, rd, a, b); endfunction
  function void mul(int rd, int a, int b);  r(6'h03, rd, a, b); endfunction
  function void addi(int rd, int a, int imm); i(6'h0A, rd, a, imm); endfunction
  function void s2r(int rd, int k);         i(6'h0C, rd, 0, k); endfunction
  function void ld(int rd, int base, int ofs);  i(6'h18, rd, base, ofs); endfunction
  function void st(int rs, int base, int ofs);  i(6'h19, rs, base, ofs); endfunction   // data register in the rd field
  function void lds(int rd, int base, int ofs); i(6'h1A, rd, base, ofs); endfunction
  function void sts(int rs, int base, int ofs); i(6'h1B, rs, base, ofs); endfunction
  function void bar();  emit({6'h23, 26'd0}); endfunction
  function void exit_(); emit({6'h3F, 26'd0}); endfunction
  // load a 32-bit constant: LUI takes bits [31:14], ADDI adds bits [13:0] (always positive)
  function void li(int rd, bit [31:0] v);
    i(6'h0B, rd, 0, int'(v[31:14]));
    i(6'h0A, rd, rd, int'(v[13:0]));
  endfunction
  // conditional branch: go to target if (ra == rb) for BEQ / (ra != rb) for BNE; join is the reconvergence label
  function void br(bit [5:0] op, int ra, int rb, string target, string join_l);
    fix_t f; f.at = code.size(); f.target = target; f.join_l = join_l;
    fixes.push_back(f);
    emit({op, 4'(ra), 4'(rb), 18'd0});
  endfunction
  function void beq(int ra, int rb, string t, string j); br(6'h20, ra, rb, t, j); endfunction
  function void bne(int ra, int rb, string t, string j); br(6'h21, ra, rb, t, j); endfunction
  function void jmp(string t); br(6'h22, 0, 0, t, ""); endfunction

  function void finish();
    foreach (fixes[k]) begin
      int at = fixes[k].at;
      int t = labels[fixes[k].target] - at;
      int j = (fixes[k].join_l == "") ? 0 : labels[fixes[k].join_l] - at;
      if (t < -256 || t > 255 || j < 0 || j > 511) $error("branch out of range in %s", name);
      code[at][17:0] = {9'(t), 9'(j)};
    end
  endfunction
endclass
