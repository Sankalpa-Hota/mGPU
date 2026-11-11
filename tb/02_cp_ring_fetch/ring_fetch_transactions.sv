// The CPU appends a batch of command dwords to the ring, then writes the new WPTR.
class ring_cmd extends uvm_sequence_item;
  `uvm_object_utils(ring_cmd)
  rand int n;          // dwords to append
  rand int gap;        // idle cycles before this batch
  int max_n = 12, max_gap = 10;
  bit [31:0] data[];
  constraint c_n   { n inside {[1:max_n]}; }
  constraint c_gap { gap dist {0 :/ 40, [1:max_gap] :/ 60}; }
  function new(string name = "ring_cmd");
    super.new(name);
  endfunction
  function void post_randomize();
    data = new[n];
    foreach (data[i]) data[i] = $urandom;
  endfunction
endclass

class ring_dw_item extends uvm_sequence_item;    // one dword delivered to the decoder
  `uvm_object_utils(ring_dw_item)
  bit [31:0] data;
  bit [RING_LOG2-1:0] rptr_before;
  function new(string name = "ring_dw_item");
    super.new(name);
  endfunction
endclass

class ring_req_item extends uvm_sequence_item;   // one memory request and its response
  `uvm_object_utils(ring_req_item)
  bit [31:0] addr;
  int        latency;
  bit [RING_LOG2-1:0] wptr_at_issue;
  bit [RING_LOG2-1:0] rptr_at_issue;
  function new(string name = "ring_req_item");
    super.new(name);
  endfunction
endclass

class ring_wptr_item extends uvm_sequence_item;  // the CPU moved WPTR: these dwords are new work
  `uvm_object_utils(ring_wptr_item)
  bit [RING_LOG2-1:0] old_wptr, new_wptr;
  bit [31:0] data[$];
  bit        wrapped;
  bit        req_in_flight;
  function new(string name = "ring_wptr_item");
    super.new(name);
  endfunction
endclass
