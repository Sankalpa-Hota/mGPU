class icache_env extends uvm_env;
  `uvm_component_utils(icache_env)
  uvm_sequencer #(icache_fetch) sqr[2];
  icache_fetch_driver     drv[2];
  icache_memory_responder memr;
  icache_checker          chk;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    for (int p = 0; p < 2; p++) begin
      sqr[p] = uvm_sequencer#(icache_fetch)::type_id::create($sformatf("sqr%0d", p), this);
      drv[p] = icache_fetch_driver::type_id::create($sformatf("drv%0d", p), this);
      drv[p].port = p;
    end
    memr = icache_memory_responder::type_id::create("memr", this);
    chk  = icache_checker::type_id::create("chk", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    for (int p = 0; p < 2; p++) drv[p].seq_item_port.connect(sqr[p].seq_item_export);
  endfunction
endclass
