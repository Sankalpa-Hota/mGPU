typedef virtual simt_interface simt_vif_t;
import mgpu_pkg::*;
localparam int DEPTH = 7;

// A random structured program: straight-line code, if/else, if-only, loops and early exits, emitted with the
// real mGPU branch encoding (target and join offsets in instructions).
class simt_program extends uvm_object;
  `uvm_object_utils(simt_program)
  bit [31:0] code[$];
  int max_depth = 3, max_items = 4;
  int uniform_pct = 0;      // chance that a branch decides the same for all lanes
  function new(string name = "simt_program");
    super.new(name);
  endfunction

  function bit [31:0] plain();   return {OP_ADD, 26'h0}; endfunction
  function bit [31:0] br(bit [5:0] op, int target, int join_off);
    return {op, 8'h0, 9'(target), 9'(join_off)};
  endfunction

  function void gen(int d);
    int n = $urandom_range(max_items, 1);
    repeat (n) begin
      int r = $urandom_range(99);
      if (d >= max_depth || r < 40) begin
        repeat ($urandom_range(3, 1)) code.push_back(plain());
      end else if (r < 60) begin                      // if / else
        int b, j, e;
        b = code.size(); code.push_back(0);
        gen(d + 1);
        j = code.size(); code.push_back(0);
        e = code.size();
        gen(d + 1);
        code[b] = br(OP_BEQ, e - b, code.size() - b);
        code[j] = br(OP_JMP, code.size() - j, 0);
      end else if (r < 75) begin                      // if only
        int b = code.size();
        code.push_back(0);
        gen(d + 1);
        code[b] = br(OP_BEQ, code.size() - b, code.size() - b);
      end else if (r < 90) begin                      // loop
        int s = code.size(), b;
        gen(d + 1);
        b = code.size();
        code.push_back(br(OP_BNE, s - b, 1));
      end else begin                                  // some lanes leave early
        int b = code.size();
        code.push_back(0);
        code.push_back(plain());
        code.push_back({OP_EXIT, 26'h0});
        code[b] = br(OP_BEQ, code.size() - b, code.size() - b);
      end
    end
  endfunction

  function void build();
    code.delete();
    gen(0);
    code.push_back({OP_EXIT, 26'h0});
  endfunction

  function bit [31:0] at(bit [31:0] pc);
    return (pc / 4 < code.size()) ? code[pc / 4] : {OP_EXIT, 26'h0};
  endfunction
endclass

// Branch decisions. A lane's k-th visit to the branch at pc decides the same way in the DUT run and in the
// scalar reference run. Loop branches stop after 4 iterations so every program terminates.
class simt_decider extends uvm_object;
  `uvm_object_utils(simt_decider)
  int seed;
  int uniform_pct;
  function new(string name = "simt_decider");
    super.new(name);
  endfunction
  function bit [31:0] hash(bit [31:0] x);
    x = x ^ (x >> 16); x = x * 32'h7feb352d; x = x ^ (x >> 15); x = x * 32'h846ca68b; x = x ^ (x >> 16);
    return x;
  endfunction
  function bit taken(bit [31:0] pc, bit [31:0] instr, int lane, int visit);
    bit [31:0] h = hash(seed ^ (pc << 8) ^ (visit << 20));
    bit uniform = (h % 100) < uniform_pct;
    bit [31:0] hl = uniform ? hash(h) : hash(h ^ (lane * 32'h9E3779B9));
    if (f_op(instr) == OP_BNE && $signed(f_target(instr)) < 0) return (visit < 4) && (hl % 3 != 0);
    return hl[0];
  endfunction
endclass
