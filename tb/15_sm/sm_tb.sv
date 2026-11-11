typedef virtual sm_interface sm_vif_t;

class sm_config extends uvm_object;
  `uvm_object_utils(sm_config)
  int mem_rdy_pct = 80, mem_min_lat = 2, mem_max_lat = 10;
  function new(string name = "sm_config"); super.new(name); endfunction
endclass

// DUT-side global memory (word granular, byte strobes on write), default 0 like the ISS.
class sm_memory extends uvm_object;
  `uvm_object_utils(sm_memory)
  bit [31:0] w[bit [31:0]];
  function new(string name = "sm_memory"); super.new(name); endfunction
  function bit [31:0] rd(bit [31:0] a); a[1:0] = 0; return w.exists(a) ? w[a] : 0; endfunction
endclass

// writes the same initial data into the DUT memory and the ISS
class sm_both_writer extends mgpu_data_writer;
  sm_memory m; mgpu_iss iss;
  function new(sm_memory m, mgpu_iss iss); this.m = m; this.iss = iss; endfunction
  virtual function void write(bit [31:0] a, bit [31:0] d); m.w[a] = d; iss.wr(a, d); endfunction
endclass

// Plays everything below the SM (crossbar, L2, DRAM): random readiness and latency, line reads and strobed
// line writes acknowledged after the latency.
class sm_memory_responder extends uvm_component;
  `uvm_component_utils(sm_memory_responder)
  sm_vif_t vif; sm_config cfg; sm_memory mem;
  int n_rd, n_wr;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(sm_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(sm_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(sm_memory)::get(this, "", "mem", mem));
  endfunction
  task run_phase(uvm_phase phase);
    vif.mreq_ready = 0; vif.mrsp_valid = 0; vif.mrsp_data = 0;
    forever begin
      bit [31:0] a, st; bit we; bit [255:0] d;
      @(posedge vif.clk); #1;
      vif.mreq_ready = ($urandom_range(99) < cfg.mem_rdy_pct);
      @(negedge vif.clk);
      if (!(vif.mreq_valid && vif.mreq_ready)) continue;
      a = vif.mreq_addr; we = vif.mreq_we; d = vif.mreq_wdata; st = vif.mreq_wstrb;
      @(posedge vif.clk); #1;
      vif.mreq_ready = 0;
      repeat ($urandom_range(cfg.mem_max_lat, cfg.mem_min_lat)) @(posedge vif.clk);
      #1;
      for (int i = 0; i < 8; i++) begin
        bit [31:0] wa = a + 4 * i, v = mem.rd(wa);
        if (we) begin
          for (int b = 0; b < 4; b++) if (st[4 * i + b]) v[8*b +: 8] = d[32*i + 8*b +: 8];
          if (st[4*i +: 4] != 0) mem.w[wa] = v;
        end
        vif.mrsp_data[32*i +: 32] = we ? 0 : v;
      end
      if (we) n_wr++; else n_rd++;
      vif.mrsp_valid = 1;
      @(posedge vif.clk); #1;
      vif.mrsp_valid = 0;
    end
  endtask
endclass

// Statistics and coverage of what happened inside the SM, read from the sub-cores (white box).
class sm_coverage extends uvm_component;
  `uvm_component_utils(sm_coverage)
  sm_vif_t vif;
  mgpu_coverage cov;
  longint issued, cycles, l1_hits;
  int max_depth;
  string names[$] = '{"kernel_vector_add", "kernel_saxpy", "kernel_reduction", "kernel_divergence", "kernel_sfu",
                      "kernel_exit_barrier", "kernel_smem_conflict", "kernel_random", "simt_depth_3", "simt_depth_5", "barrier_release",
                      "smem_bank_conflict", "lsu_coalesced_1_line", "lsu_scattered_lines", "l1_hit",
                      "both_subcores_busy", "wg_1_warp", "wg_4_warps", "more_workgroups_than_subcores"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("sm");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(sm_vif_t)::get(this, "", "vif", vif));
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      cycles++;
      issued += $countones(vif.stat_issue);
      if (vif.stat_l1_hit_pulse) begin l1_hits++; cov.sample("l1_hit"); end
      if (tb_top.dut.g_sub[0].u_sub.active && tb_top.dut.g_sub[1].u_sub.active) cov.sample("both_subcores_busy");
      begin
        int d0 = tb_top.dut.g_sub[0].u_sub.stat_simt_depth, d1 = tb_top.dut.g_sub[1].u_sub.stat_simt_depth;
        int d = (d0 > d1) ? d0 : d1;
        if (d > max_depth) max_depth = d;
        if (d >= 3) cov.sample("simt_depth_3");
        if (d >= 5) cov.sample("simt_depth_5");
      end
      if (tb_top.dut.g_sub[0].u_sub.release_mask != 0 || tb_top.dut.g_sub[1].u_sub.release_mask != 0) cov.sample("barrier_release");
      if (tb_top.dut.g_sub[0].u_sub.u_smem.rsp_valid && tb_top.dut.g_sub[0].u_sub.stat_smem_passes > 1) cov.sample("smem_bank_conflict");
      if (tb_top.dut.g_sub[1].u_sub.u_smem.rsp_valid && tb_top.dut.g_sub[1].u_sub.stat_smem_passes > 1) cov.sample("smem_bank_conflict");
      // a global load/store finished (LSU in its pick state with nothing left): how many lines did it need?
      if (tb_top.dut.g_sub[0].u_sub.u_lsu.state == 3 && tb_top.dut.g_sub[0].u_sub.u_lsu.pend == 0)
        cov.sample(tb_top.dut.g_sub[0].u_sub.u_lsu.lines == 1 ? "lsu_coalesced_1_line" : "lsu_scattered_lines");
      if (tb_top.dut.g_sub[1].u_sub.u_lsu.state == 3 && tb_top.dut.g_sub[1].u_sub.u_lsu.pend == 0)
        cov.sample(tb_top.dut.g_sub[1].u_sub.u_lsu.lines == 1 ? "lsu_coalesced_1_line" : "lsu_scattered_lines");
    end
  endtask
endclass

// Runs kernels like the driver software: data into memory, invalidate, launch every workgroup on a free
// sub-core, and when the last workgroup is done compare the whole memory with the ISS at once.
class sm_runner extends uvm_component;
  `uvm_component_utils(sm_runner)
  sm_vif_t vif; sm_memory mem; sm_coverage scov;
  mgpu_iss iss;
  int n_err, n_kernels;
  function new(string name, uvm_component parent); super.new(name, parent); iss = new(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(sm_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(sm_memory)::get(this, "", "mem", mem));
  endfunction
  function void err(string s); n_err++; `uvm_error("KERNEL", s) endfunction

  task run_kernel(mgpu_kernel k);
    sm_both_writer w = new(mem, iss);
    bit sub_busy[2];
    int next = 0, finished = 0, t0, mism = 0;
    longint iss0 = scov.issued, cyc0 = scov.cycles;
    k.setup(w);
    if (!iss.run_kernel(k.pc0, k.num_wg, k.nw, k.arg)) err($sformatf("%s: ISS failed: %s", k.name, iss.error));
    scov.cov.sample({"kernel_", (k.name inside {"vector_add", "saxpy", "reduction", "divergence", "sfu", "exit_barrier", "smem_conflict"}) ? k.name : "random"});
    if (k.nw == 1) scov.cov.sample("wg_1_warp");
    if (k.nw == 4) scov.cov.sample("wg_4_warps");
    if (k.num_wg > 2) scov.cov.sample("more_workgroups_than_subcores");
    @(posedge vif.clk); #1;
    vif.invalidate = 1;
    @(posedge vif.clk); #1;
    vif.invalidate = 0;
    t0 = $time;
    while (finished < k.num_wg) begin
      vif.launch_valid = 0;
      for (int s = 0; s < 2; s++) if (vif.wg_done[s]) begin sub_busy[s] = 0; finished++; end
      if (next < k.num_wg)
        for (int s = 0; s < 2; s++)
          if (!sub_busy[s] && !vif.launch_valid) begin
            vif.launch_valid = 1; vif.launch_sub = s; vif.launch_wg_id = next; vif.launch_nwarps = k.nw;
            vif.launch_pc = k.pc0; vif.launch_arg = k.arg;
            sub_busy[s] = 1; next++;
          end
      @(posedge vif.clk); #1;
      if (($time - t0) / 10 > 2000000) begin err($sformatf("%s: timeout, %0d of %0d workgroups done", k.name, finished, k.num_wg)); break; end
    end
    vif.launch_valid = 0;
    // compare right away, like the CPU reading results after the completion interrupt
    foreach (iss.mem[a]) if (mem.rd(a) !== iss.mem[a]) begin
      if (mism < 5) err($sformatf("%s: memory[%08h] = %08h, ISS expects %08h", k.name, a, mem.rd(a), iss.mem[a]));
      mism++;
    end
    foreach (mem.w[a]) if (!iss.mem.exists(a) && mem.w[a] != 0) begin
      if (mism < 5) err($sformatf("%s: memory[%08h] = %08h written but ISS never wrote it", k.name, a, mem.w[a]));
      mism++;
    end
    n_kernels++;
    `uvm_info("KERNEL", $sformatf("%-13s wg=%0d warps/wg=%0d threads=%0d  cycles=%0d  instructions=%0d  IPC=%0.2f  mismatches=%0d",
              k.name, k.num_wg, k.nw, k.threads(), scov.cycles - cyc0, scov.issued - iss0,
              real'(scov.issued - iss0) / real'(scov.cycles - cyc0), mism), UVM_LOW)
  endtask
  function void report_phase(uvm_phase phase);
    `uvm_info("KERNEL", $sformatf("kernels=%0d errors=%0d L1 read hits=%0d max SIMT stack depth=%0d", n_kernels, n_err, scov.l1_hits, scov.max_depth), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", scov.cov.percent(), scov.cov.report()), UVM_LOW)
  endfunction
endclass

class sm_env extends uvm_env;
  `uvm_component_utils(sm_env)
  sm_memory_responder memr; sm_coverage scov; sm_runner run;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    memr = sm_memory_responder::type_id::create("memr", this);
    scov = sm_coverage::type_id::create("scov", this);
    run  = sm_runner::type_id::create("run", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    run.scov = scov;
  endfunction
endclass

class sm_base_test extends uvm_test;
  `uvm_component_utils(sm_base_test)
  sm_env env; sm_config cfg; sm_memory mem; sm_vif_t vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = sm_config::type_id::create("cfg");
    mem = sm_memory::type_id::create("mem");
    knobs();
    uvm_config_db#(sm_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(sm_memory)::set(this, "env.*", "mem", mem);
    void'(uvm_config_db#(sm_vif_t)::get(this, "", "vif", vif));
    env = sm_env::type_id::create("env", this);
  endfunction
  virtual task kernels();
    mgpu_kernel k = new("vector_add", 4, 2);
    env.run.run_kernel(k);
  endtask
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    vif.launch_valid = 0; vif.invalidate = 0; vif.launch_sub = 0;
    wait (vif.rst_n === 1);
    repeat (3) @(posedge vif.clk);
    kernels();
    repeat (10) @(posedge vif.clk);
    if (vif.stat_overflow) `uvm_error("SIMT", "SIMT stack overflow during the test")
    phase.drop_objection(this);
  endtask
endclass

class sm_vector_add_test extends sm_base_test;
  `uvm_component_utils(sm_vector_add_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class sm_kernels_test extends sm_base_test;
  `uvm_component_utils(sm_kernels_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task kernels();
    string names[$] = '{"vector_add", "saxpy", "reduction", "divergence", "sfu", "exit_barrier", "smem_conflict"};
    int shapes[$] = '{1, 2, 4};
    foreach (names[i]) foreach (shapes[j]) begin
      mgpu_kernel k = new(names[i], 5, shapes[j]);
      env.run.run_kernel(k);
    end
  endtask
endclass

class sm_random_kernel_test extends sm_base_test;
  `uvm_component_utils(sm_random_kernel_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task kernels();
    repeat (12) begin
      mgpu_kernel k = new("random", $urandom_range(6, 1), $urandom_range(4, 1), $urandom);
      env.run.run_kernel(k);
    end
  endtask
endclass

class sm_slow_memory_test extends sm_kernels_test;
  `uvm_component_utils(sm_slow_memory_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.mem_rdy_pct = 30; cfg.mem_min_lat = 10; cfg.mem_max_lat = 40; endfunction
endclass
