class cp_base_test extends uvm_test;
  `uvm_component_utils(cp_base_test)
  cp_env env;
  cp_cfg cfg;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = cp_cfg::type_id::create("cfg");
    uvm_config_db#(cp_cfg)::set(this, "env.agt.*", "cfg", cfg);
    env = cp_env::type_id::create("env", this);
  endfunction
  virtual task run_seq();
  endtask
  task run_phase(uvm_phase phase);
    virtual cp_if vif;
    void'(uvm_config_db#(virtual cp_if)::get(this, "env.agt.drv", "vif", vif));
    phase.raise_objection(this);
    run_seq();
    repeat (20) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass

class cp_directed_test extends cp_base_test;
  `uvm_component_utils(cp_directed_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  task run_seq();
    cp_directed_seq s = cp_directed_seq::type_id::create("s");
    s.start(env.agt.sqr);
  endtask
endclass

class cp_rand_test extends cp_base_test;
  `uvm_component_utils(cp_rand_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual function void knobs(cp_rand_seq s);
    s.n = 400; s.max_gap = 3; cfg.ready_pct = 80;
  endfunction
  task run_seq();
    cp_rand_seq s = cp_rand_seq::type_id::create("s");
    knobs(s);
    s.start(env.agt.sqr);
  endtask
endclass

class cp_backpressure_test extends cp_rand_test;
  `uvm_component_utils(cp_backpressure_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void knobs(cp_rand_seq s);
    s.n = 300; s.max_gap = 0; cfg.ready_pct = 25;
  endfunction
endclass

class cp_bad_pkt_test extends cp_rand_test;
  `uvm_component_utils(cp_bad_pkt_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void knobs(cp_rand_seq s);
    s.n = 300; s.bad_w = 15; s.max_gap = 2; cfg.ready_pct = 70;
  endfunction
endclass

class cp_corner_test extends cp_rand_test;
  `uvm_component_utils(cp_corner_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void knobs(cp_rand_seq s);
    s.n = 300; s.zero_w = 30; s.max_w = 20; s.wrap_w = 30; cfg.ready_pct = 60;
  endfunction
endclass
