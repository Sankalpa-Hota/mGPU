typedef virtual mmu_interface mmu_vif_t;
localparam bit [31:0] PTBR = 32'h0010_0000;

class mmu_config extends uvm_object;
  `uvm_object_utils(mmu_config)
  int mem_rdy_pct = 70, mem_max_lat = 6, write_pct = 40, bad_pct = 15, remap_every = 0, n_pages = 6;
  bit enable = 1;
  function new(string name = "mmu_config"); super.new(name); endfunction
endclass

// Physical memory, holding the page tables and the data pages.
class mmu_phys extends uvm_object;
  `uvm_object_utils(mmu_phys)
  bit [31:0] w[bit [31:0]];
  int next_l2 = 1, next_page = 0;
  function new(string name = "mmu_phys"); super.new(name); endfunction
  function bit [31:0] rd(bit [31:0] a); a[1:0] = 0; return w.exists(a) ? w[a] : (a * 32'h01000193); endfunction
  function bit [255:0] line(bit [31:0] a);
    for (int i = 0; i < 8; i++) line[32*i +: 32] = rd({a[31:5], 5'd0} + 4 * i);
  endfunction
  // map virtual page vpn to a fresh physical page; writable or read-only
  function void map(bit [19:0] vpn, bit writable);
    bit [31:0] l1a = PTBR + 4 * vpn[19:10], pte1 = rd(l1a), l2a;
    if (!w.exists(l1a) || !pte1[0]) begin
      pte1 = (PTBR + 32'h1000 * next_l2++) | 1;
      w[l1a] = pte1;
    end
    l2a = {pte1[31:12], 12'd0} + 4 * vpn[9:0];
    w[l2a] = ((32'h0020_0000 + 32'h1000 * next_page++) & 32'hFFFF_F000) | (writable ? 3 : 1);
  endfunction
  function void unmap(bit [19:0] vpn);
    bit [31:0] pte1 = rd(PTBR + 4 * vpn[19:10]);
    if (w.exists(PTBR + 4 * vpn[19:10]) && pte1[0]) w[{pte1[31:12], 12'd0} + 4 * vpn[9:0]] = 0;
  endfunction
  // reference translation: 0 ok, 1 level-1 fault, 2 level-2 fault, 3 write to read-only
  function int translate(bit [31:0] va, bit we, output bit [31:0] pa, output bit [31:0] pte);
    bit [31:0] l1a = PTBR + 4 * va[31:22], p1 = w.exists(l1a) ? w[l1a] : 0, p2;
    pa = 0; pte = 0;
    if (!p1[0]) return 1;
    p2 = w.exists({p1[31:12], 12'd0} + 4 * va[21:12]) ? w[{p1[31:12], 12'd0} + 4 * va[21:12]] : 0;
    pte = p2;
    if (!p2[0]) return 2;
    pa = {p2[31:12], va[11:5], 5'd0};
    if (we && !p2[1]) return 3;
    return 0;
  endfunction
endclass

// virtual pages used by the tests: two level-1 regions, plus a region with no level-1 entry at all
function automatic bit [19:0] mmu_vpn(int k);
  case (k % 3)
    0: return 20'h00400 + k;     // L1 index 1
    1: return 20'h00C00 + k;     // L1 index 3
    default: return 20'h00800 + k;  // L1 index 2: never mapped -> level-1 fault
  endcase
endfunction

class mmu_driver extends uvm_component;
  `uvm_component_utils(mmu_driver)
  mmu_vif_t vif; mmu_config cfg;
  int n = 200;
  bit done;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(mmu_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(mmu_config)::get(this, "", "cfg", cfg));
  endfunction
  task one();
    int k = $urandom_range(cfg.n_pages * 3 - 1);
    if ($urandom_range(99) >= cfg.bad_pct && k % 3 == 2) k = k - 2;
    vif.req_valid = 1;
    vif.req_addr = {mmu_vpn(k), 7'($urandom), 5'd0};
    vif.req_we = ($urandom_range(99) < cfg.write_pct);
    for (int i = 0; i < 8; i++) vif.req_wdata[32*i +: 32] = $urandom;
    vif.req_wstrb = $urandom_range(1) ? '1 : $urandom;
    do @(negedge vif.clk); while (!vif.req_ready);
    @(posedge vif.clk); #1;
    vif.req_valid = 0;
    while (!vif.rsp_valid) @(negedge vif.clk);
    @(posedge vif.clk); #1;
  endtask
endclass

class mmu_phys_responder extends uvm_component;
  `uvm_component_utils(mmu_phys_responder)
  mmu_vif_t vif; mmu_config cfg; mmu_phys mem;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(mmu_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(mmu_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(mmu_phys)::get(this, "", "mem", mem));
  endfunction
  task run_phase(uvm_phase phase);
    vif.mreq_ready = 0; vif.mrsp_valid = 0;
    forever begin
      bit [31:0] a, st; bit we; bit [255:0] d;
      @(posedge vif.clk); #1;
      vif.mreq_ready = ($urandom_range(99) < cfg.mem_rdy_pct);
      @(negedge vif.clk);
      if (!(vif.mreq_valid && vif.mreq_ready)) continue;
      a = vif.mreq_addr; we = vif.mreq_we; d = vif.mreq_wdata; st = vif.mreq_wstrb;
      if (we) for (int i = 0; i < 8; i++) begin
        bit [31:0] v = mem.rd(a + 4 * i);
        for (int b = 0; b < 4; b++) if (st[4 * i + b]) v[8*b +: 8] = d[32*i + 8*b +: 8];
        if (st[4*i +: 4] != 0) mem.w[a + 4 * i] = v;
      end
      @(posedge vif.clk); #1;
      vif.mreq_ready = 0;
      repeat ($urandom_range(cfg.mem_max_lat)) @(posedge vif.clk);
      #1;
      vif.mrsp_data = we ? '0 : mem.line(a);
      vif.mrsp_valid = 1;
      @(posedge vif.clk); #1;
      vif.mrsp_valid = 0;
    end
  endtask
endclass

// Reference translation from the page tables in memory + a model of the TLB (8 entries, round-robin, filled
// after a successful level-2 read, cleared by invalidate). Predicts the exact downstream requests.
class mmu_checker extends uvm_component;
  `uvm_component_utils(mmu_checker)
  mmu_vif_t vif; mmu_phys mem; mmu_config cfg;
  mgpu_coverage cov;
  bit        t_valid[8]; bit [19:0] t_vpn[8], t_ppn[8]; bit t_w[8]; int t_rr;
  typedef struct { bit [31:0] addr; bit we; } dreq_t;
  dreq_t exp_q[$];
  bit open, exp_err, have_fault;
  bit [31:0] c_va; bit c_we; bit [255:0] c_wdata;
  bit [31:0] exp_fault_va; bit exp_fault_we; bit fault_pending_report;
  int n, n_err, distinct_since_inval;
  bit invalidated_recently;
  string names[$] = '{"tlb_hit", "walk", "fault_level1", "fault_level2", "fault_write_readonly_walk", "fault_write_readonly_tlb_hit",
                      "read_readonly_ok", "tlb_replacement", "invalidate_then_walk", "remapped_page_used", "bypass",
                      "fault_reported", "fault_cleared", "memory_backpressure"};
  bit [19:0] remapped[$];
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("mmu");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(mmu_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(mmu_phys)::get(this, "", "mem", mem));
    void'(uvm_config_db#(mmu_config)::get(this, "", "cfg", cfg));
  endfunction
  function void err(string s); n_err++; `uvm_error("CHK", s) endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      if (vif.mreq_valid && !vif.mreq_ready) cov.sample("memory_backpressure");
      if (vif.mreq_valid && vif.mreq_ready) begin
        if (exp_q.size() == 0) err($sformatf("unexpected memory request %08h we=%b", vif.mreq_addr, vif.mreq_we));
        else begin
          dreq_t e = exp_q.pop_front();
          if (vif.mreq_addr !== e.addr || vif.mreq_we !== e.we) err($sformatf("memory request %08h we=%b, expected %08h we=%b (va %08h)", vif.mreq_addr, vif.mreq_we, e.addr, e.we, c_va));
          if (e.we && vif.mreq_wdata !== c_wdata) err("write data changed through the MMU");
        end
      end
      if (vif.rsp_valid) begin
        n++;
        if (!open) err("answer with no request");
        if (vif.rsp_err !== exp_err) err($sformatf("va %08h: err=%b, expected %b", c_va, vif.rsp_err, exp_err));
        if (exp_q.size() != 0) err($sformatf("va %08h answered before %0d expected memory requests", c_va, exp_q.size()));
        open = 0;
      end
      if (vif.fault_valid && fault_pending_report) begin
        if (vif.fault_va !== exp_fault_va || vif.fault_write !== exp_fault_we) err($sformatf("fault recorded va %08h w=%b, expected %08h w=%b", vif.fault_va, vif.fault_write, exp_fault_va, exp_fault_we));
        cov.sample("fault_reported");
        fault_pending_report = 0;
      end
      if (vif.fault_clear) begin have_fault = 0; cov.sample("fault_cleared"); end
      if (vif.tlb_invalidate) begin
        foreach (t_valid[i]) t_valid[i] = 0;
        invalidated_recently = 1;
      end
      if (vif.req_valid && vif.req_ready) accept();
    end
  endtask

  function void accept();
    bit [31:0] pa, pte; int r, hit = -1;
    open = 1; exp_err = 0;
    c_va = vif.req_addr; c_we = vif.req_we; c_wdata = vif.req_wdata;
    if (!vif.enable) begin
      dreq_t d; d.addr = {c_va[31:5], 5'd0}; d.we = c_we; exp_q.push_back(d);
      cov.sample("bypass");
      return;
    end
    foreach (t_valid[i]) if (t_valid[i] && t_vpn[i] == c_va[31:12]) hit = i;
    if (hit >= 0) begin
      cov.sample("tlb_hit");
      if (c_we && !t_w[hit]) begin fault_now(); cov.sample("fault_write_readonly_tlb_hit"); return; end
      begin dreq_t d; d.addr = {t_ppn[hit], c_va[11:5], 5'd0}; d.we = c_we; exp_q.push_back(d); end
      if (!c_we && !t_w[hit]) cov.sample("read_readonly_ok");
      return;
    end
    cov.sample("walk");
    if (invalidated_recently) begin cov.sample("invalidate_then_walk"); invalidated_recently = 0; end
    foreach (remapped[i]) if (remapped[i] == c_va[31:12]) begin cov.sample("remapped_page_used"); remapped.delete(i); break; end
    r = mem.translate(c_va, c_we, pa, pte);
    begin dreq_t d; d.addr = {PTBR[31:12], 12'd0} + 4 * c_va[31:22]; d.addr[4:0] = 0; d.we = 0; exp_q.push_back(d); end
    if (r == 1) begin fault_now(); cov.sample("fault_level1"); return; end
    begin
      bit [31:0] p1 = mem.rd(PTBR + 4 * c_va[31:22]);
      dreq_t d; d.addr = {p1[31:12], 12'd0} + 4 * c_va[21:12]; d.addr[4:0] = 0; d.we = 0; exp_q.push_back(d);
    end
    if (r == 2) begin fault_now(); cov.sample("fault_level2"); return; end
    // successful level-2 read: the TLB is filled (also when the write then faults)
    if (t_valid[t_rr]) cov.sample("tlb_replacement");
    t_valid[t_rr] = 1; t_vpn[t_rr] = c_va[31:12]; t_ppn[t_rr] = pte[31:12]; t_w[t_rr] = pte[1];
    t_rr = (t_rr + 1) % 8;
    if (r == 3) begin fault_now(); cov.sample("fault_write_readonly_walk"); return; end
    if (!c_we && !pte[1]) cov.sample("read_readonly_ok");
    begin dreq_t d; d.addr = pa; d.we = c_we; exp_q.push_back(d); end
  endfunction

  function void fault_now();
    exp_err = 1;
    if (!have_fault) begin
      have_fault = 1; exp_fault_va = c_va; exp_fault_we = c_we; fault_pending_report = 1;
    end
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("translations=%0d errors=%0d", n, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class mmu_env extends uvm_env;
  `uvm_component_utils(mmu_env)
  mmu_driver drv; mmu_phys_responder memr; mmu_checker chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    drv = mmu_driver::type_id::create("drv", this);
    memr = mmu_phys_responder::type_id::create("memr", this);
    chk = mmu_checker::type_id::create("chk", this);
  endfunction
endclass

class mmu_base_test extends uvm_test;
  `uvm_component_utils(mmu_base_test)
  mmu_env env; mmu_config cfg; mmu_phys mem; mmu_vif_t vif;
  int n = 100;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = mmu_config::type_id::create("cfg");
    mem = mmu_phys::type_id::create("mem");
    knobs();
    uvm_config_db#(mmu_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(mmu_phys)::set(this, "env.*", "mem", mem);
    void'(uvm_config_db#(mmu_vif_t)::get(this, "", "vif", vif));
    env = mmu_env::type_id::create("env", this);
  endfunction
  // page tables: pages of L1 regions 1 and 3; every 4th page read-only, every 5th unmapped
  function void build_tables();
    for (int k = 0; k < cfg.n_pages * 3; k++)
      if (k % 3 != 2) begin
        if (k % 5 == 4) continue;
        mem.map(mmu_vpn(k), (k % 4) != 3);
      end
  endfunction
  task pulse(ref logic s);
    @(posedge vif.clk); #1; s = 1;
    @(posedge vif.clk); #1; s = 0;
  endtask
  // software: change a mapping in memory, then invalidate the TLB
  task remap();
    int k = $urandom_range(cfg.n_pages * 3 - 1);
    if (k % 3 == 2) k--;
    mem.map(mmu_vpn(k), $urandom_range(1));
    env.chk.remapped.push_back(mmu_vpn(k));
    pulse(vif.tlb_invalidate);
  endtask
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    vif.enable = cfg.enable; vif.ptbr = PTBR; vif.tlb_invalidate = 0; vif.fault_clear = 0; vif.req_valid = 0;
    build_tables();
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    for (int i = 0; i < n; i++) begin
      env.drv.one();
      if (vif.fault_valid && $urandom_range(3) == 0) pulse(vif.fault_clear);
      if (cfg.remap_every != 0 && i % cfg.remap_every == cfg.remap_every - 1) remap();
    end
    repeat (5) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class mmu_smoke_test extends mmu_base_test;
  `uvm_component_utils(mmu_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class mmu_rand_test extends mmu_base_test;
  `uvm_component_utils(mmu_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 3000; cfg.n_pages = 8; endfunction
endclass
class mmu_remap_test extends mmu_base_test;
  `uvm_component_utils(mmu_remap_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 3000; cfg.remap_every = 25; cfg.n_pages = 4; endfunction
endclass
class mmu_tlb_thrash_test extends mmu_base_test;
  `uvm_component_utils(mmu_tlb_thrash_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 3000; cfg.n_pages = 12; cfg.bad_pct = 5; endfunction
endclass
class mmu_bypass_test extends mmu_base_test;
  `uvm_component_utils(mmu_bypass_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 500; cfg.enable = 0; endfunction
endclass
