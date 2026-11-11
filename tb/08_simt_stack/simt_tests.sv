class simt_base_test extends uvm_test;
  `uvm_component_utils(simt_base_test)
  simt_env env;
  int programs = 3, rounds = 3, max_depth = 3, max_items = 4, uniform_pct = 20, gap_pct = 20;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = simt_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    knobs();
    repeat (programs) begin
      env.prog.max_depth = max_depth; env.prog.max_items = max_items;
      env.prog.build();
      `uvm_info("PROG", $sformatf("program of %0d instructions", env.prog.code.size()), UVM_LOW)
      env.dec.uniform_pct = uniform_pct;
      env.exe.rounds = rounds; env.exe.gap_pct = gap_pct;
      env.exe.run_rounds();
    end
    phase.drop_objection(this);
  endtask
endclass

class simt_smoke_test extends simt_base_test;
  `uvm_component_utils(simt_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); programs = 1; rounds = 1; max_depth = 1; endfunction
endclass

class simt_rand_test extends simt_base_test;
  `uvm_component_utils(simt_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); programs = 30; rounds = 4; endfunction
endclass

class simt_uniform_test extends simt_base_test;
  `uvm_component_utils(simt_uniform_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); programs = 20; rounds = 3; uniform_pct = 90; endfunction
endclass

class simt_deep_test extends simt_base_test;
  `uvm_component_utils(simt_deep_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); programs = 30; rounds = 3; max_depth = 3; max_items = 6; uniform_pct = 0; gap_pct = 0; endfunction
endclass

class simt_overflow_test extends simt_base_test;
  `uvm_component_utils(simt_overflow_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); programs = 10; rounds = 2; max_depth = 5; max_items = 3; uniform_pct = 0; endfunction
endclass
