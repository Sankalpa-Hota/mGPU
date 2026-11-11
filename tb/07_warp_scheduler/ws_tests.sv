// This block has no sequence of transactions to drive: its whole environment is reactive (fetch, SIMT and
// execution models answer the DUT), and the "stimulus" is the random program plus the model knobs.
class ws_base_test extends uvm_test;
  `uvm_component_utils(ws_base_test)
  ws_env env; ws_config cfg; ws_program prog; ws_vif_t vif;
  int cycles = 3000;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = ws_config::type_id::create("cfg");
    prog = ws_program::type_id::create("prog");
    prog.cfg = cfg;
    prog.seed = $urandom;
    knobs();
    uvm_config_db#(ws_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(ws_program)::set(this, "env.*", "prog", prog);
    void'(uvm_config_db#(ws_vif_t)::get(this, "", "vif", vif));
    env = ws_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    int t = 0;
    phase.raise_objection(this);
    repeat (cycles) @(posedge vif.clk);
    // end of test: nothing is relaunched; every warp runs until its own EXIT and all writebacks drain
    cfg.stop = 1;
    while ((vif.live != 0 || !env.exec.empty()) && t < 20000) begin @(posedge vif.clk); t++; end
    if (vif.live != 0) `uvm_error("DRAIN", $sformatf("warps still live at the end: %b", vif.live))
    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass

class ws_smoke_test extends ws_base_test;
  `uvm_component_utils(ws_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 500; endfunction
endclass

class ws_rand_test extends ws_base_test;
  `uvm_component_utils(ws_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 20000; endfunction
endclass

class ws_hazard_test extends ws_base_test;
  `uvm_component_utils(ws_hazard_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 15000; cfg.reg_span = 3; cfg.sfu_max_lat = 40; cfg.lsu_max_lat = 25; cfg.ctrl_pct = 3; endfunction
endclass

class ws_throughput_test extends ws_base_test;
  `uvm_component_utils(ws_throughput_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 15000; cfg.reg_span = 16; cfg.issue_rdy_pct = 100; cfg.fetch_rdy_pct = 100; cfg.fetch_max_lat = 0; cfg.ctrl_pct = 2; cfg.sfu_max_lat = 5; cfg.lsu_max_lat = 3; endfunction
endclass

class ws_backpressure_test extends ws_base_test;
  `uvm_component_utils(ws_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 15000; cfg.issue_rdy_pct = 20; cfg.fetch_rdy_pct = 40; endfunction
endclass

class ws_control_test extends ws_base_test;
  `uvm_component_utils(ws_control_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 15000; cfg.ctrl_pct = 30; cfg.exit_pct = 30; endfunction
endclass
