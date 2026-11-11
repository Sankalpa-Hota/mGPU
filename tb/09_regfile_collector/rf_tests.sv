class rf_base_test extends uvm_test;
  `uvm_component_utils(rf_base_test)
  rf_env env; rf_config cfg; rf_hazards hz; rf_vif_t vif;
  int cycles = 2000;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = rf_config::type_id::create("cfg");
    hz  = rf_hazards::type_id::create("hz");
    knobs();
    uvm_config_db#(rf_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(rf_hazards)::set(this, "env.*", "hz", hz);
    void'(uvm_config_db#(rf_vif_t)::get(this, "", "vif", vif));
    env = rf_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    repeat (cycles) @(posedge vif.clk);
    env.iss.stop = 1;
    for (int k = 0; k < 3; k++) env.wb[k].stop = 1;
    cfg.ex_rdy_pct = 100;
    repeat (20) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass

class rf_smoke_test extends rf_base_test;
  `uvm_component_utils(rf_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 300; endfunction
endclass

class rf_rand_test extends rf_base_test;
  `uvm_component_utils(rf_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 30000; endfunction
endclass

class rf_bank_stress_test extends rf_base_test;
  `uvm_component_utils(rf_bank_stress_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 20000; cfg.reg_span = 4; cfg.wb_pct = 90; cfg.issue_pct = 90; cfg.ex_rdy_pct = 100; endfunction
endclass

class rf_backpressure_test extends rf_base_test;
  `uvm_component_utils(rf_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 20000; cfg.ex_rdy_pct = 15; cfg.launch_pct = 5; endfunction
endclass
