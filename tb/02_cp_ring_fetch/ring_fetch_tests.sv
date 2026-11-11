class ring_fetch_base_test extends uvm_test;
  `uvm_component_utils(ring_fetch_base_test)
  ring_fetch_env env;
  ring_fetch_config cfg;
  ring_memory mem;
  ring_vif_t vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual function void knobs();
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = ring_fetch_config::type_id::create("cfg");
    mem = ring_memory::type_id::create("mem");
    knobs();
    uvm_config_db#(ring_fetch_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(ring_memory)::set(this, "env.*", "mem", mem);
    void'(uvm_config_db#(ring_vif_t)::get(this, "", "vif", vif));
    env = ring_fetch_env::type_id::create("env", this);
  endfunction
  virtual task run_seq();
    ring_rand_seq s = ring_rand_seq::type_id::create("s");
    s.n_batches = 20;
    s.start(env.sqr);
  endtask
  task run_phase(uvm_phase phase);
    int t = 0;
    phase.raise_objection(this);
    run_seq();
    // drain: everything published must be delivered and the block must go idle
    while ((vif.wptr != vif.rptr || vif.busy) && t < 20000) begin @(posedge vif.clk); t++; end
    if (t >= 20000) `uvm_error("DRAIN", $sformatf("did not drain: wptr=%0d rptr=%0d busy=%0b", vif.wptr, vif.rptr, vif.busy))
    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass

class ring_fetch_smoke_test extends ring_fetch_base_test;
  `uvm_component_utils(ring_fetch_smoke_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass

class ring_fetch_rand_test extends ring_fetch_base_test;
  `uvm_component_utils(ring_fetch_rand_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void knobs();
    cfg.sink_pct = 70; cfg.mem_min_lat = 0; cfg.mem_max_lat = 6; cfg.req_rdy_pct = 70;
  endfunction
  task run_seq();
    ring_rand_seq s = ring_rand_seq::type_id::create("s");
    s.n_batches = 300;
    s.start(env.sqr);
  endtask
endclass

class ring_fetch_slow_sink_test extends ring_fetch_rand_test;
  `uvm_component_utils(ring_fetch_slow_sink_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void knobs();
    cfg.sink_pct = 15; cfg.mem_max_lat = 2;
  endfunction
endclass

class ring_fetch_slow_mem_test extends ring_fetch_rand_test;
  `uvm_component_utils(ring_fetch_slow_mem_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void knobs();
    cfg.mem_min_lat = 5; cfg.mem_max_lat = 20; cfg.req_rdy_pct = 40;
  endfunction
endclass

class ring_fetch_full_ring_test extends ring_fetch_base_test;
  `uvm_component_utils(ring_fetch_full_ring_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void knobs();
    cfg.sink_pct = 50;
  endfunction
  task run_seq();
    ring_full_seq s = ring_full_seq::type_id::create("s");
    s.start(env.sqr);
  endtask
endclass

class ring_fetch_wrap_stress_test extends ring_fetch_base_test;
  `uvm_component_utils(ring_fetch_wrap_stress_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void knobs();
    cfg.sink_pct = 90; cfg.mem_max_lat = 3;
  endfunction
  task run_seq();
    ring_rand_seq s = ring_rand_seq::type_id::create("s");
    s.n_batches = 500; s.max_n = 3; s.max_gap = 1;
    s.start(env.sqr);
  endtask
endclass
