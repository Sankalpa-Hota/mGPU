typedef virtual icache_interface icache_vif_t;
localparam int LINES = 16;

class icache_config extends uvm_object;
  `uvm_object_utils(icache_config)
  int mem_min_lat = 1, mem_max_lat = 6, mem_rdy_pct = 80;
  bit pause = 0;            // fetch drivers stop issuing new requests (used to quiesce before a code rewrite)
  function new(string name = "icache_config");
    super.new(name);
  endfunction
endclass

// Instruction memory. Contents are a function of the address and a version number; "rewriting the code"
// is bumping the version, which changes every word at once.
class icache_memory extends uvm_object;
  `uvm_object_utils(icache_memory)
  int version = 0;
  function new(string name = "icache_memory");
    super.new(name);
  endfunction
  function bit [31:0] word(bit [31:0] byte_addr);
    bit [31:0] a = {byte_addr[31:2], 2'b00};
    return (a * 32'h9E37_79B1) ^ (version * 32'h7F4A_7C15) ^ 32'h1234_5678;
  endfunction
endclass
