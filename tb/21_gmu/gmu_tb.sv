typedef virtual gmu_interface gmu_vif_t;
localparam int WAKE = 6;

class gmu_config extends uvm_object;
  `uvm_object_utils(gmu_config)
  int work_pct = 3;        // chance per cycle that new work arrives for an SM
  int job_max = 30;        // job length
  int blip_pct = 0;        // chance per cycle of a one-cycle busy blip while idle (e.g. a late store ack)
  int limit_min = 1, limit_max = 20;
  bit change_limit = 0;
  function new(string name = "gmu_config"); super.new(name); endfunction
endclass

// Plays the dispatcher and the SMs: work arrives at random; the dispatcher wants an SM while it has work for it;
// a job starts only on an available SM and keeps it busy for a while.
class gmu_workload extends uvm_component;
  `uvm_component_utils(gmu_workload)
  gmu_vif_t vif; gmu_config cfg;
  int pending[2], left[2];
  bit stop;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(gmu_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(gmu_config)::get(this, "", "cfg", cfg));
  endfunction
  task run_phase(uvm_phase phase);
    vif.sm_busy = 0; vif.sm_want = 0; vif.idle_limit = $urandom_range(cfg.limit_max, cfg.limit_min);
    wait (vif.rst_n === 1);
    forever begin
      @(posedge vif.clk); #1;
      if (cfg.change_limit && $urandom_range(499) == 0) vif.idle_limit = $urandom_range(3) == 0 ? 0 : $urandom_range(cfg.limit_max, cfg.limit_min);
      for (int m = 0; m < 2; m++) begin
        if (!stop && $urandom_range(99) < cfg.work_pct) pending[m]++;
        if (left[m] > 0) left[m]--;
        // the dispatcher reacts one cycle after it starts wanting the SM (as the real one does)
        else if (pending[m] > 0 && vif.sm_avail[m] && vif.sm_want[m]) begin pending[m]--; left[m] = $urandom_range(cfg.job_max, 1); end
        vif.sm_busy[m] = (left[m] > 0) || (left[m] == 0 && $urandom_range(99) < cfg.blip_pct && vif.sm_avail[m]);
        vif.sm_want[m] = (pending[m] > 0);
      end
    end
  endtask
endclass

// Spec model of each SM's power state machine, compared with the DUT every cycle.
class gmu_checker extends uvm_component;
  `uvm_component_utils(gmu_checker)
  gmu_vif_t vif;
  mgpu_coverage cov;
  int st[2], idle[2], wake[2];     // 0 ON, 1 OFF, 2 WAKING
  int n_off, n_wake, n_err;
  string names[$] = '{"power_off_sm0", "power_off_sm1", "wake_sm0", "wake_sm1", "both_off", "one_on_one_off",
                      "want_during_waking", "idle_count_reset_by_want", "idle_count_reset_by_busy", "gating_disabled",
                      "limit_1", "wake_complete"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("gmu");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(gmu_vif_t)::get(this, "", "vif", vif));
  endfunction
  function void err(string s); n_err++; `uvm_error("CHK", s) endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      if (vif.sm_power == 0) cov.sample("both_off");
      if (vif.sm_power == 2'b01 || vif.sm_power == 2'b10) cov.sample("one_on_one_off");
      if (vif.idle_limit == 0) cov.sample("gating_disabled");
      if (vif.idle_limit == 1) cov.sample("limit_1");
      for (int m = 0; m < 2; m++) begin
        if (vif.sm_avail[m] !== (st[m] == 0) || vif.sm_power[m] !== (st[m] != 1))
          err($sformatf("SM%0d avail=%b power=%b, model state %0d", m, vif.sm_avail[m], vif.sm_power[m], st[m]));
        if (vif.sm_busy[m] && st[m] != 0) err($sformatf("SM%0d busy while not ON (state %0d)", m, st[m]));
        case (st[m])
          0: begin
            if (vif.sm_busy[m] && idle[m] > 0) cov.sample("idle_count_reset_by_busy");
            if (vif.sm_want[m] && idle[m] > 0) cov.sample("idle_count_reset_by_want");
            if (vif.sm_busy[m] || vif.sm_want[m] || vif.idle_limit == 0) idle[m] = 0;
            else if (idle[m] == vif.idle_limit - 1) begin st[m] = 1; idle[m] = 0; n_off++; cov.sample($sformatf("power_off_sm%0d", m)); end
            else idle[m]++;
          end
          1: if (vif.sm_want[m]) begin st[m] = 2; wake[m] = WAKE; n_wake++; cov.sample($sformatf("wake_sm%0d", m)); end
          default: begin
            if (vif.sm_want[m]) cov.sample("want_during_waking");
            if (wake[m] <= 1) begin st[m] = 0; cov.sample("wake_complete"); end else wake[m]--;
          end
        endcase
      end
    end
  endtask
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("power-offs=%0d wake-ups=%0d errors=%0d", n_off, n_wake, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class gmu_env extends uvm_env;
  `uvm_component_utils(gmu_env)
  gmu_workload wl; gmu_checker chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    wl = gmu_workload::type_id::create("wl", this);
    chk = gmu_checker::type_id::create("chk", this);
  endfunction
endclass

class gmu_base_test extends uvm_test;
  `uvm_component_utils(gmu_base_test)
  gmu_env env; gmu_config cfg; gmu_vif_t vif;
  int cycles = 3000;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = gmu_config::type_id::create("cfg");
    knobs();
    uvm_config_db#(gmu_config)::set(this, "env.*", "cfg", cfg);
    void'(uvm_config_db#(gmu_vif_t)::get(this, "", "vif", vif));
    env = gmu_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    int t = 0;
    phase.raise_objection(this);
    repeat (cycles) @(posedge vif.clk);
    env.wl.stop = 1;
    while ((env.wl.pending[0] + env.wl.pending[1] + env.wl.left[0] + env.wl.left[1]) != 0 && t < 5000) begin @(posedge vif.clk); t++; end
    if (t >= 5000) `uvm_error("STARVE", "work never ran: an SM did not wake up")
    repeat (50) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class gmu_smoke_test extends gmu_base_test;
  `uvm_component_utils(gmu_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class gmu_rand_test extends gmu_base_test;
  `uvm_component_utils(gmu_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 60000; cfg.change_limit = 1; cfg.blip_pct = 2; endfunction
endclass
class gmu_bursty_test extends gmu_base_test;
  `uvm_component_utils(gmu_bursty_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 40000; cfg.work_pct = 1; cfg.job_max = 8; cfg.limit_min = 1; cfg.limit_max = 4; endfunction
endclass
class gmu_blip_test extends gmu_base_test;
  `uvm_component_utils(gmu_blip_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 40000; cfg.work_pct = 1; cfg.blip_pct = 15; cfg.limit_min = 5; cfg.limit_max = 12; endfunction
endclass
