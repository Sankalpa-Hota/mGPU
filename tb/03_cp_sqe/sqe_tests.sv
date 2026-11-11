class sqe_base_test extends uvm_test;
  `uvm_component_utils(sqe_base_test)
  sqe_env env;
  sqe_config cfg;
  sqe_vif_t vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual function void knobs();
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = sqe_config::type_id::create("cfg");
    knobs();
    uvm_config_db#(sqe_config)::set(this, "env.*", "cfg", cfg);
    void'(uvm_config_db#(sqe_vif_t)::get(this, "", "vif", vif));
    env = sqe_env::type_id::create("env", this);
  endfunction
  virtual task run_seq();
    sqe_rand_seq s = sqe_rand_seq::type_id::create("s");
    s.n = 30;
    s.start(env.sqr);
  endtask
  task run_phase(uvm_phase phase);
    int t = 0;
    phase.raise_objection(this);
    run_seq();
    while (vif.busy && t < 5000) begin @(posedge vif.clk); t++; end
    cfg.bg_busy_pct = 0;    // stop background traffic so every job can finish
    while (vif.busy_in != 0 && t < 5000) begin @(posedge vif.clk); t++; end
    if (t >= 5000) `uvm_error("DRAIN", "SQE did not return to idle")
    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass

class sqe_smoke_test extends sqe_base_test;
  `uvm_component_utils(sqe_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class sqe_rand_test extends sqe_base_test;
  `uvm_component_utils(sqe_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs();
    cfg.disp_rdy_pct = 60; cfg.mem_rdy_pct = 60; cfg.ack_max = 8; cfg.bg_busy_pct = 3; cfg.busy_delay_max = SETTLE;
  endfunction
  task run_seq();
    sqe_rand_seq s = sqe_rand_seq::type_id::create("s");
    s.n = 500;
    s.start(env.sqr);
  endtask
endclass

class sqe_wfi_race_test extends sqe_base_test;
  `uvm_component_utils(sqe_wfi_race_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs();
    cfg.busy_delay_max = SETTLE; cfg.work_min = 1; cfg.work_max = 6;
  endfunction
  task run_seq();
    sqe_wfi_race_seq s = sqe_wfi_race_seq::type_id::create("s");
    s.start(env.sqr);
  endtask
endclass

class sqe_event_test extends sqe_base_test;
  `uvm_component_utils(sqe_event_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs();
    cfg.mem_rdy_pct = 40; cfg.ack_min = 0; cfg.ack_max = 12;
  endfunction
  task run_seq();
    sqe_event_seq s = sqe_event_seq::type_id::create("s");
    s.start(env.sqr);
  endtask
endclass

class sqe_unknown_op_test extends sqe_rand_test;
  `uvm_component_utils(sqe_unknown_op_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_seq();
    sqe_rand_seq s = sqe_rand_seq::type_id::create("s");
    s.n = 200; s.unknown_w = 15;
    s.start(env.sqr);
  endtask
endclass

class sqe_busy_storm_test extends sqe_rand_test;
  `uvm_component_utils(sqe_busy_storm_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs();
    cfg.bg_busy_pct = 8; cfg.work_max = 60; cfg.disp_rdy_pct = 80;
  endfunction
endclass
