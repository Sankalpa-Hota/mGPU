typedef virtual dram_interface dram_vif_t;
localparam int MW = 20;

class dram_config extends uvm_object;
  `uvm_object_utils(dram_config)
  int n_reads = 200, n_writes = 200, bad_pct = 5, oor_pct = 5, rdy_pct = 80, same_row_pct = 50;
  function new(string name = "dram_config"); super.new(name); endfunction
endclass

// golden memory (bytes; zero when never written) and response rules, shared by the two master streams
class dram_ref extends uvm_object;
  `uvm_object_utils(dram_ref)
  bit [7:0] b[bit [31:0]];
  bit [19:0] last_addr = 0;
  function new(string name = "dram_ref"); super.new(name); endfunction
  function bit [31:0] rd(bit [31:0] a);
    for (int i = 0; i < 4; i++) rd[8*i +: 8] = b.exists(a + i) ? b[a + i] : 0;
  endfunction
  static function bit [1:0] resp(bit [31:0] a, int len, int size, int burst);
    if (burst != 1 || size != 2 || len > 15) return 2'b10;
    if (a >= (32'd1 << MW) || a + (len + 1) * 4 > (32'd1 << MW)) return 2'b11;
    return 2'b00;
  endfunction
  // a burst start address: often near the previous one (same DRAM row), sometimes far, sometimes out of range
  function bit [31:0] pick(int len, dram_config cfg);
    bit [31:0] a;
    if ($urandom_range(99) < cfg.oor_pct) return 32'h0010_0000 + 32'h1000 * $urandom_range(15);   // page aligned: no 4 KB crossing
    if ($urandom_range(99) < cfg.same_row_pct) a = {last_addr[19:12], 12'(4 * $urandom_range(1023))};
    else a = 4 * $urandom_range((1 << (MW - 2)) - 1);
    if ((a & 32'hFFF) + (len + 1) * 4 > 32'h1000) a = (a & ~32'hFFF) + 32'h1000 - (len + 1) * 4;   // stay inside one 4 KB page
    last_addr = a;
    return a;
  endfunction
endclass

// AXI master with an independent read stream and write stream (one of each in flight at a time).
// Reads are checked beat by beat against the golden memory as the data arrives.
class dram_master extends uvm_component;
  `uvm_component_utils(dram_master)
  dram_vif_t vif; dram_config cfg; dram_ref ref_m;
  mgpu_coverage cov;
  int n_err, n_rd, n_wr;
  bit rd_done, wr_done, rd_pending, wr_pending;
  bit [31:0] w_lo, w_hi;    // byte range of the write burst in flight
  typedef struct { bit [31:0] lo, hi; time done; } wlog_t;
  wlog_t wlog[$];           // finished writes, to see which ones overlapped a read in time
  int n_unordered;
  string names[$] = '{"read", "write", "len_1", "len_2_15", "len_16", "slverr_burst_type", "slverr_size", "decerr",
                      "partial_strobe", "read_and_write_pending", "both_start_same_cycle", "rready_backpressure",
                      "bready_backpressure", "row_hit", "row_miss"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("dram_ctrl");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(dram_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(dram_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(dram_ref)::get(this, "", "ref", ref_m));
  endfunction
  function void err(string s); n_err++; `uvm_error("CHK", s) endfunction
  function bit racing(bit [31:0] a, time t_ar);
    if (wr_pending && a >= w_lo && a < w_hi) return 1;
    foreach (wlog[k]) if (wlog[k].done >= t_ar && a >= wlog[k].lo && a < wlog[k].hi) return 1;
    return 0;
  endfunction
  function void attrs(output int len, output int size, output int burst);
    len = ($urandom_range(3) == 0) ? 0 : ($urandom_range(5) == 0) ? 15 : $urandom_range(14, 1);
    size = 2; burst = 1;
    if ($urandom_range(99) < cfg.bad_pct) begin
      if ($urandom_range(1)) begin burst = $urandom_range(1) ? 0 : 2; cov.sample("slverr_burst_type"); end
      else begin size = $urandom_range(1); cov.sample("slverr_size"); end
    end
    cov.sample(len == 0 ? "len_1" : len == 15 ? "len_16" : "len_2_15");
  endfunction

  task reads();
    repeat (cfg.n_reads) begin
      int len, size, burst; bit [31:0] a; bit [1:0] er; time t_ar;
      attrs(len, size, burst);
      a = ref_m.pick(len, cfg); er = dram_ref::resp(a, len, size, burst);
      if (er == 2'b11) cov.sample("decerr");
      @(posedge vif.clk); #1;
      vif.arvalid = 1; vif.araddr = a; vif.arlen = len; vif.arsize = size; vif.arburst = burst;
      rd_pending = 1;
      if (wr_pending) cov.sample("read_and_write_pending");
      do @(negedge vif.clk); while (!vif.arready);
      t_ar = $time;
      if (vif.awvalid) cov.sample("both_start_same_cycle");
      @(posedge vif.clk); #1; vif.arvalid = 0;
      for (int i = 0; i <= len; i++) begin
        vif.rready = ($urandom_range(99) < cfg.rdy_pct);
        @(negedge vif.clk);
        while (!(vif.rvalid && vif.rready)) begin
          if (vif.rvalid) cov.sample("rready_backpressure");
          @(posedge vif.clk); #1; vif.rready = ($urandom_range(99) < cfg.rdy_pct); @(negedge vif.clk);
        end
        if (vif.rresp !== er) err($sformatf("read %08h beat %0d: resp %0d, expected %0d", a, i, vif.rresp, er));
        else if (er == 0 && racing(a + 4 * i, t_ar)) n_unordered++;   // a write to this word overlapped the read in time: AXI gives no order
        else if (er == 0 && vif.rdata !== ref_m.rd(a + 4 * i)) err($sformatf("read %08h beat %0d: %08h, expected %08h", a, i, vif.rdata, ref_m.rd(a + 4 * i)));
        if (vif.rlast !== (i == len)) err($sformatf("read burst of %0d beats: RLAST=%b on beat %0d", len + 1, vif.rlast, i));
        @(posedge vif.clk); #1;
        vif.rready = 0;
      end
      rd_pending = 0; n_rd++; cov.sample("read");
    end
    rd_done = 1;
  endtask

  task writes();
    repeat (cfg.n_writes) begin
      int len, size, burst; bit [31:0] a; bit [1:0] er;
      bit [31:0] d[16]; bit [3:0] s[16];
      attrs(len, size, burst);
      a = ref_m.pick(len, cfg); er = dram_ref::resp(a, len, size, burst);
      if (er == 2'b11) cov.sample("decerr");
      for (int i = 0; i <= len; i++) begin
        d[i] = $urandom; s[i] = ($urandom_range(2) == 0) ? 4'($urandom) : 4'hF;
        if (s[i] != 4'hF) cov.sample("partial_strobe");
      end
      @(posedge vif.clk); #1;
      vif.awvalid = 1; vif.awaddr = a; vif.awlen = len; vif.awsize = size; vif.awburst = burst;
      wr_pending = 1; w_lo = a; w_hi = a + (len + 1) * 4;
      do @(negedge vif.clk); while (!vif.awready);
      @(posedge vif.clk); #1; vif.awvalid = 0;
      for (int i = 0; i <= len; i++) begin
        vif.wvalid = 1; vif.wdata = d[i]; vif.wstrb = s[i]; vif.wlast = (i == len);
        do @(negedge vif.clk); while (!vif.wready);
        @(posedge vif.clk); #1;
      end
      vif.wvalid = 0; vif.wlast = 0;
      // the golden memory changes when the write is complete
      if (er == 0) for (int i = 0; i <= len; i++) for (int k = 0; k < 4; k++) if (s[i][k]) ref_m.b[a + 4 * i + k] = d[i][8*k +: 8];
      vif.bready = ($urandom_range(99) < cfg.rdy_pct);
      @(negedge vif.clk);
      while (!(vif.bvalid && vif.bready)) begin
        if (vif.bvalid) cov.sample("bready_backpressure");
        @(posedge vif.clk); #1; vif.bready = ($urandom_range(99) < cfg.rdy_pct); @(negedge vif.clk);
      end
      if (vif.bresp !== er) err($sformatf("write %08h: resp %0d, expected %0d", a, vif.bresp, er));
      @(posedge vif.clk); #1; vif.bready = 0;
      begin wlog_t l; l.lo = w_lo; l.hi = w_hi; l.done = $time; wlog.push_back(l); if (wlog.size() > 8) void'(wlog.pop_front()); end
      wr_pending = 0; n_wr++; cov.sample("write");
    end
    wr_done = 1;
  endtask

  // row-buffer model: the controller must report a hit exactly when the bank's open row matches
  bit [7:0] m_row[4]; bit m_ok[4];
  // every cycle: first check last cycle's prediction (the stat pulse is registered), then take a new burst start
  task row_watch();
    bit pend; bit exp_hit; bit [31:0] pa;
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      if (pend) begin
        if (vif.stat_row_hit !== exp_hit || vif.stat_row_miss !== !exp_hit) err($sformatf("burst at %08h: row hit=%b reported, model says %b", pa, vif.stat_row_hit, exp_hit));
        cov.sample(exp_hit ? "row_hit" : "row_miss");
        pend = 0;
      end
      for (int c = 0; c < 2; c++) begin
        bit go = (c == 0) ? (vif.arvalid && vif.arready) : (vif.awvalid && vif.awready);
        bit [31:0] a = (c == 0) ? vif.araddr : vif.awaddr;
        int len = (c == 0) ? vif.arlen : vif.awlen, size = (c == 0) ? vif.arsize : vif.awsize, burst = (c == 0) ? vif.arburst : vif.awburst;
        if (go && dram_ref::resp(a, len, size, burst) == 0) begin
          exp_hit = m_ok[a[11:10]] && m_row[a[11:10]] == a[19:12];
          pend = 1; pa = a;
          m_ok[a[11:10]] = 1; m_row[a[11:10]] = a[19:12];
        end
      end
    end
  endtask

  task run_phase(uvm_phase phase);
    vif.arvalid = 0; vif.awvalid = 0; vif.wvalid = 0; vif.rready = 0; vif.bready = 0; vif.wlast = 0;
    wait (vif.rst_n === 1);
    fork reads(); writes(); row_watch(); join_none
  endtask
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("read bursts=%0d write bursts=%0d errors=%0d (read beats racing a write, not checked: %0d)", n_rd, n_wr, n_err, n_unordered), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class dram_env extends uvm_env;
  `uvm_component_utils(dram_env)
  dram_master m;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    m = dram_master::type_id::create("m", this);
  endfunction
endclass

class dram_base_test extends uvm_test;
  `uvm_component_utils(dram_base_test)
  dram_env env; dram_config cfg; dram_ref ref_m; dram_vif_t vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = dram_config::type_id::create("cfg");
    ref_m = dram_ref::type_id::create("ref_m");
    knobs();
    uvm_config_db#(dram_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(dram_ref)::set(this, "env.*", "ref", ref_m);
    void'(uvm_config_db#(dram_vif_t)::get(this, "", "vif", vif));
    env = dram_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    int t = 0;
    phase.raise_objection(this);
    while (!(env.m.rd_done && env.m.wr_done) && t < 2000000) begin @(posedge vif.clk); t++; end
    if (t >= 2000000) `uvm_error("HANG", "bursts did not finish")
    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class dram_smoke_test extends dram_base_test;
  `uvm_component_utils(dram_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.n_reads = 30; cfg.n_writes = 30; endfunction
endclass
class dram_rand_test extends dram_base_test;
  `uvm_component_utils(dram_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.n_reads = 2000; cfg.n_writes = 2000; endfunction
endclass
class dram_row_test extends dram_base_test;
  `uvm_component_utils(dram_row_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.n_reads = 1500; cfg.n_writes = 1500; cfg.same_row_pct = 90; cfg.bad_pct = 0; cfg.oor_pct = 0; endfunction
endclass
class dram_error_test extends dram_base_test;
  `uvm_component_utils(dram_error_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.n_reads = 800; cfg.n_writes = 800; cfg.bad_pct = 25; cfg.oor_pct = 25; cfg.rdy_pct = 40; endfunction
endclass
