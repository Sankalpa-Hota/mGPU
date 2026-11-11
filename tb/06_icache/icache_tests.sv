class icache_base_test extends uvm_test;
  `uvm_component_utils(icache_base_test)
  icache_env env;
  icache_config cfg;
  icache_memory mem;
  icache_vif_t vif;
  int n = 20, max_len = 12, max_gap = 2;
  bit [31:0] region = 32'h1000;
  int rewrites = 0;        // code rewrites + invalidate during the test
  int inval_in_miss = 0;   // invalidates pulsed while a miss is in flight (code unchanged)
  int hi_pct = 0;          // streams in the high-address alias (catches partial tag compares)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual function void knobs();
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = icache_config::type_id::create("cfg");
    mem = icache_memory::type_id::create("mem");
    knobs();
    uvm_config_db#(icache_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(icache_memory)::set(this, "env.*", "mem", mem);
    void'(uvm_config_db#(icache_vif_t)::get(this, "", "vif", vif));
    env = icache_env::type_id::create("env", this);
  endfunction
  task pulse_invalidate();
    @(posedge vif.clk); #1; vif.invalidate = 1;
    @(posedge vif.clk); #1; vif.invalidate = 0;
  endtask
  // the software rule: stop fetching, rewrite code, invalidate, resume
  task rewrite_code();
    cfg.pause = 1;
    repeat (2) @(posedge vif.clk);
    while (vif.req_valid != 0 || env.chk.miss_open || env.chk.outstanding[0] || env.chk.outstanding[1]) @(posedge vif.clk);
    mem.version++;
    pulse_invalidate();
    cfg.pause = 0;
  endtask
  task run_port(int p);
    icache_rand_seq s = icache_rand_seq::type_id::create($sformatf("s%0d", p));
    s.n = n; s.max_len = max_len; s.max_gap = max_gap; s.region = region; s.hi_pct = hi_pct;
    s.start(env.sqr[p]);
  endtask
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    vif.invalidate = 0;
    wait (vif.rst_n === 1);
    fork
      run_port(0);
      run_port(1);
      begin
        repeat (rewrites) begin repeat ($urandom_range(400, 100)) @(posedge vif.clk); rewrite_code(); end
      end
      begin
        repeat (inval_in_miss) begin
          repeat ($urandom_range(150, 30)) @(posedge vif.clk);
          while (!env.chk.miss_open) @(posedge vif.clk);
          pulse_invalidate();
        end
      end
    join
    repeat (20) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass

class icache_smoke_test extends icache_base_test;
  `uvm_component_utils(icache_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class icache_rand_test extends icache_base_test;
  `uvm_component_utils(icache_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 200; region = 32'h2000; hi_pct = 25; cfg.mem_rdy_pct = 60; cfg.mem_max_lat = 10; endfunction
endclass

class icache_stream_test extends icache_base_test;
  `uvm_component_utils(icache_stream_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 60; max_len = 64; region = 32'h400; max_gap = 0; endfunction
endclass

class icache_contention_test extends icache_base_test;
  `uvm_component_utils(icache_contention_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 150; region = 32'h200; max_gap = 0; max_len = 20; endfunction
endclass

class icache_invalidate_test extends icache_base_test;
  `uvm_component_utils(icache_invalidate_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 150; region = 32'h400; rewrites = 10; inval_in_miss = 10; cfg.mem_max_lat = 12; endfunction
endclass
