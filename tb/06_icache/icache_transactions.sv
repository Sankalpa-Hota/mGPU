// A fetch stream: like a warp running straight-line code, it fetches len consecutive instructions from pc.
class icache_fetch extends uvm_sequence_item;
  `uvm_object_utils(icache_fetch)
  rand bit [31:0] pc;
  rand int        len;
  rand int        gap;
  bit [31:0] region = 32'h0000_1000;   // size of the code region in bytes
  int max_len = 12, max_gap = 2;
  int hi_pct = 0;     // share of streams placed in the high-address alias of the region
  constraint c_pc  { pc[1:0] == 0; pc < region; }
  constraint c_len { len inside {[1:max_len]}; }
  constraint c_gap { gap inside {[0:max_gap]}; }
  function new(string name = "icache_fetch");
    super.new(name);
  endfunction
  function void post_randomize();
    if (hi_pct > 0 && $urandom_range(99) < hi_pct) pc = pc | 32'h8000_0000;   // same index, tag differs in its top bit
  endfunction
endclass
