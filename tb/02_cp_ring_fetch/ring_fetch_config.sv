localparam int RING_LOG2 = 6;              // 64-dword ring: small so the testbench wraps it often
localparam int RING_SIZE = 1 << RING_LOG2;
typedef virtual ring_fetch_interface #(RING_LOG2) ring_vif_t;

class ring_fetch_config extends uvm_object;
  `uvm_object_utils(ring_fetch_config)
  bit [31:0] ring_base   = 32'h0000_4000;
  int        sink_pct    = 100;   // chance per cycle that the decoder side takes a dword
  int        mem_min_lat = 0;     // memory response latency range in cycles
  int        mem_max_lat = 4;
  int        req_rdy_pct = 100;   // chance per cycle that the memory accepts a request
  function new(string name = "ring_fetch_config");
    super.new(name);
  endfunction
endclass

// The DRAM contents as one shared object: the CPU agent writes it, the memory responder and the monitor read it.
class ring_memory extends uvm_object;
  `uvm_object_utils(ring_memory)
  bit [31:0] dw[bit [31:0]];   // key: byte address of the dword
  function new(string name = "ring_memory");
    super.new(name);
  endfunction
  function bit [31:0] read(bit [31:0] a);
    return dw.exists(a) ? dw[a] : 32'hDEAD_BEEF;
  endfunction
endclass
