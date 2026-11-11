class dispatcher_base_test extends uvm_test;
  `uvm_component_utils(dispatcher_base_test)
  dispatcher_env env;
  dispatcher_config cfg;
  disp_vif_t vif;
  int n = 10, max_wg = 6;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual function void knobs();
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = dispatcher_config::type_id::create("cfg");
    knobs();
    uvm_config_db#(dispatcher_config)::set(this, "env.*", "cfg", cfg);
    void'(uvm_config_db#(disp_vif_t)::get(this, "", "vif", vif));
    env = dispatcher_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    disp_rand_seq s = disp_rand_seq::type_id::create("s");
    int t = 0;
    phase.raise_objection(this);
    s.n = n; s.max_wg = max_wg;
    s.start(env.sqr);
    cfg.sleep_pct = 0; cfg.wake_pct = 100;
    while (vif.busy && t < 20000) begin @(posedge vif.clk); t++; end
    if (vif.busy) `uvm_error("DRAIN", "dispatcher still busy at the end")
    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass

class dispatcher_smoke_test extends dispatcher_base_test;
  `uvm_component_utils(dispatcher_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class dispatcher_rand_test extends dispatcher_base_test;
  `uvm_component_utils(dispatcher_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 150; max_wg = 12; cfg.sleep_pct = 3; endfunction
endclass

class dispatcher_full_test extends dispatcher_base_test;
  `uvm_component_utils(dispatcher_full_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 40; max_wg = 40; cfg.run_min = 30; cfg.run_max = 120; endfunction
endclass

class dispatcher_power_test extends dispatcher_base_test;
  `uvm_component_utils(dispatcher_power_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 80; max_wg = 10; cfg.sleep_pct = 15; cfg.wake_pct = 10; cfg.run_min = 1; cfg.run_max = 8; endfunction
endclass

class dispatcher_short_wg_test extends dispatcher_base_test;
  `uvm_component_utils(dispatcher_short_wg_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 150; max_wg = 8; cfg.run_min = 0; cfg.run_max = 3; endfunction
endclass
