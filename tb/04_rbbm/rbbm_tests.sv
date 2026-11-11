class rbbm_base_test extends uvm_test;
  `uvm_component_utils(rbbm_base_test)
  rbbm_env env;
  rbbm_config cfg;
  rbbm_vif_t vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual function void knobs();
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = rbbm_config::type_id::create("cfg");
    knobs();
    uvm_config_db#(rbbm_config)::set(this, "env.*", "cfg", cfg);
    void'(uvm_config_db#(rbbm_vif_t)::get(this, "", "vif", vif));
    env = rbbm_env::type_id::create("env", this);
  endfunction
  virtual task run_seq();
  endtask
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    wait (vif.rst_n === 1);
    repeat (2) @(posedge vif.clk);
    run_seq();
    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
  function rbbm_reg_base_seq prep(rbbm_reg_base_seq s);
    s.rm = env.rm;
    return s;
  endfunction
endclass

// Built-in RAL sequence: every register reads its documented reset value.
class rbbm_reset_value_test extends rbbm_base_test;
  `uvm_component_utils(rbbm_reset_value_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.hw_quiet = 1; endfunction
  task run_seq();
    uvm_reg_hw_reset_seq s = uvm_reg_hw_reset_seq::type_id::create("s");
    uvm_resource_db#(bit)::set({"REG::", env.rm.SOFT_RESET.get_full_name()}, "NO_REG_HW_RESET_TEST", 1, this);
    s.model = env.rm;
    s.start(null);
  endtask
endclass

// Built-in RAL sequence: walk a 1 and a 0 through every bit of every static register.
class rbbm_bit_bash_test extends rbbm_base_test;
  `uvm_component_utils(rbbm_bit_bash_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.hw_quiet = 1; endfunction
  task run_seq();
    uvm_reg_bit_bash_seq s = uvm_reg_bit_bash_seq::type_id::create("s");
    uvm_reg skip[$] = '{env.rm.ID, env.rm.RING_RPTR, env.rm.BUSY_STATUS, env.rm.IRQ_STATUS, env.rm.SOFT_RESET,
                        env.rm.PERF_CNT[0], env.rm.PERF_CNT[1], env.rm.PERF_CNT[2], env.rm.PERF_CNT[3]};
    foreach (skip[i]) uvm_resource_db#(bit)::set({"REG::", skip[i].get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
    s.model = env.rm;
    s.start(null);
  endtask
endclass

class rbbm_static_reg_test extends rbbm_base_test;
  `uvm_component_utils(rbbm_static_reg_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_seq();
    rbbm_static_reg_seq s = rbbm_static_reg_seq::type_id::create("s");
    void'(prep(s));
    s.start(null);
  endtask
endclass

class rbbm_illegal_access_test extends rbbm_base_test;
  `uvm_component_utils(rbbm_illegal_access_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_seq();
    rbbm_raw_access_seq s = rbbm_raw_access_seq::type_id::create("s");
    s.n = 400;
    s.start(env.apb.sqr);
  endtask
endclass

class rbbm_irq_test extends rbbm_base_test;
  `uvm_component_utils(rbbm_irq_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.fence_pct = 25; cfg.flag_pct = 5; endfunction
  task run_seq();
    rbbm_isr_seq s = rbbm_isr_seq::type_id::create("s");
    void'(prep(s));
    s.n = 300;
    s.start(null);
  endtask
endclass

class rbbm_hang_test extends rbbm_base_test;
  `uvm_component_utils(rbbm_hang_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.busy_pct = 3; cfg.progress_pct = 6; cfg.fence_pct = 0; endfunction
  task run_seq();
    rbbm_hang_seq s = rbbm_hang_seq::type_id::create("s");
    void'(prep(s));
    s.start(null);
  endtask
endclass

class rbbm_perf_test extends rbbm_base_test;
  `uvm_component_utils(rbbm_perf_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.perf_pct = 70; endfunction
  task run_seq();
    rbbm_perf_seq s = rbbm_perf_seq::type_id::create("s");
    void'(prep(s));
    repeat (5) s.start(null);
  endtask
endclass

class rbbm_rand_test extends rbbm_base_test;
  `uvm_component_utils(rbbm_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_seq();
    rbbm_isr_seq i = rbbm_isr_seq::type_id::create("i");
    rbbm_perf_seq p = rbbm_perf_seq::type_id::create("p");
    rbbm_hang_seq h = rbbm_hang_seq::type_id::create("h");
    rbbm_raw_access_seq r = rbbm_raw_access_seq::type_id::create("r");
    void'(prep(i)); void'(prep(p)); void'(prep(h));
    repeat (3) begin
      i.start(null); p.start(null); r.start(env.apb.sqr); h.start(null);
    end
  endtask
endclass
