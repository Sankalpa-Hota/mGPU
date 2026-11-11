typedef virtual l1_interface l1_vif_t;
localparam int SETS = 16;

class l1_config extends uvm_object;
  `uvm_object_utils(l1_config)
  int mem_rdy_pct = 70, mem_max_lat = 8, write_pct = 35, n_sets_used = 4, n_tags_used = 4, inval_pct = 0;
  function new(string name = "l1_config"); super.new(name); endfunction
endclass

class l1_memory extends uvm_object;
  `uvm_object_utils(l1_memory)
  bit [7:0] b[bit [31:0]];
  function new(string name = "l1_memory"); super.new(name); endfunction
  function bit [7:0] rd8(bit [31:0] a); return b.exists(a) ? b[a] : 8'(a * 8'h3B ^ (a >> 8)); endfunction
  function bit [255:0] line(bit [31:0] a);
    bit [255:0] l;
    for (int i = 0; i < 32; i++) l[8*i +: 8] = rd8({a[31:5], 5'd0} + i);
    return l;
  endfunction
  function void write(bit [31:0] a, bit [255:0] d, bit [31:0] st);
    for (int i = 0; i < 32; i++) if (st[i]) b[{a[31:5], 5'd0} + i] = d[8*i +: 8];
  endfunction
endclass

class l1_item extends uvm_sequence_item;
  `uvm_object_utils(l1_item)
  rand bit we;
  bit [31:0] addr, wstrb;
  bit [255:0] wdata;
  int gap;
  function new(string name = "l1_item"); super.new(name); endfunction
endclass

class l1_seq extends uvm_sequence #(l1_item);
  `uvm_object_utils(l1_seq)
  int n = 200;
  l1_config cfg;
  function new(string name = "l1_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      l1_item it = l1_item::type_id::create("it");
      int s = $urandom_range(cfg.n_sets_used - 1), tg = $urandom_range(cfg.n_tags_used - 1);
      start_item(it);
      it.we = ($urandom_range(99) < cfg.write_pct);
      it.addr = 32'h0001_0000 + tg * (SETS * 32) + s * 32 + 4 * $urandom_range(7);
      for (int i = 0; i < 8; i++) it.wdata[32*i +: 32] = $urandom;
      case ($urandom_range(3))
        0: it.wstrb = '1;
        1: it.wstrb = 32'hF << (4 * $urandom_range(7));
        default: it.wstrb = $urandom;
      endcase
      it.gap = $urandom_range(2);
      finish_item(it);
    end
  endtask
endclass

class l1_driver extends uvm_driver #(l1_item);
  `uvm_component_utils(l1_driver)
  l1_vif_t vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(l1_vif_t)::get(this, "", "vif", vif));
  endfunction
  task run_phase(uvm_phase phase);
    vif.req_valid = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.gap) begin @(posedge vif.clk); #1; end
      vif.req_valid = 1; vif.req_addr = req.addr; vif.req_we = req.we; vif.req_wdata = req.wdata; vif.req_wstrb = req.wstrb;
      do @(negedge vif.clk); while (!vif.req_ready);
      @(posedge vif.clk); #1;
      vif.req_valid = 0;
      while (!vif.rsp_valid) @(negedge vif.clk);   // one outstanding access, like the LSU
      @(posedge vif.clk); #1;
      seq_item_port.item_done();
    end
  endtask
endclass

class l1_memory_responder extends uvm_component;
  `uvm_component_utils(l1_memory_responder)
  l1_vif_t vif; l1_config cfg; l1_memory mem;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(l1_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(l1_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(l1_memory)::get(this, "", "mem", mem));
  endfunction
  task run_phase(uvm_phase phase);
    vif.mreq_ready = 0; vif.mrsp_valid = 0; vif.mrsp_data = 0; vif.invalidate = 0;
    forever begin
      bit [31:0] a, st; bit we; bit [255:0] d;
      @(posedge vif.clk); #1;
      vif.invalidate = ($urandom_range(999) < cfg.inval_pct);
      vif.mreq_ready = ($urandom_range(99) < cfg.mem_rdy_pct);
      @(negedge vif.clk);
      if (!(vif.mreq_valid && vif.mreq_ready)) continue;
      a = vif.mreq_addr; we = vif.mreq_we; d = vif.mreq_wdata; st = vif.mreq_wstrb;
      if (we) mem.write(a, d, st);
      @(posedge vif.clk); #1;
      vif.mreq_ready = 0; vif.invalidate = 0;
      repeat ($urandom_range(cfg.mem_max_lat)) @(posedge vif.clk);
      #1;
      vif.mrsp_data = we ? '0 : mem.line(a);
      vif.mrsp_valid = 1;
      @(posedge vif.clk); #1;
      vif.mrsp_valid = 0;
    end
  endtask
endclass

// Exact model of the cache state; checks requests to memory, data, hit/miss and hit latency.
class l1_checker extends uvm_component;
  `uvm_component_utils(l1_checker)
  l1_vif_t vif; l1_memory mem;
  mgpu_coverage cov;
  bit [22:0] m_tag[SETS][2];
  bit        m_valid[SETS][2];
  bit        m_lru[SETS];
  bit open, expect_mem, mem_seen, c_we, c_hit, discard;
  bit [31:0] c_addr, c_strb; bit [255:0] c_wdata;
  int due, cyc, n, n_hit, n_err;
  string names[$] = '{"read_hit_way0", "read_hit_way1", "read_miss_fill_way0", "read_miss_fill_way1", "evict_valid_line",
                      "write_hit", "write_miss_no_allocate", "partial_strobe", "lru_flip_on_hit", "invalidate_idle",
                      "invalidate_during_fill", "read_after_write_hit", "memory_backpressure"};
  bit [31:0] last_write_line = '1;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("l1_dcache");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(l1_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(l1_memory)::get(this, "", "mem", mem));
  endfunction
  function void err(string s); n_err++; `uvm_error("CHK", s) endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      cyc++;
      step();
    end
  endtask

  function void step();
    int s = c_addr[8:5];
    if (vif.mreq_valid && !vif.mreq_ready) cov.sample("memory_backpressure");
    // answer
    if (vif.rsp_valid) begin
      if (!open) err("answer with no access");
      else begin
        if (c_hit && !c_we && cyc != due) err($sformatf("read hit answered at cycle %0d, due %0d", cyc, due));
        if ((expect_mem && !mem_seen)) err("answered before the memory access");
        if (!c_we && vif.rsp_data !== mem.line(c_addr)) err($sformatf("read %08h returned stale or wrong data", c_addr));
        if (!c_we && !c_hit && !discard && !vif.invalidate) begin
          int w = m_lru[s];
          if (m_valid[s][w]) cov.sample("evict_valid_line");
          cov.sample(w ? "read_miss_fill_way1" : "read_miss_fill_way0");
          m_valid[s][w] = 1; m_tag[s][w] = c_addr[31:9]; m_lru[s] = !w;
        end
        open = 0; n++;
      end
    end
    // memory requests
    if (vif.mreq_valid && vif.mreq_ready) begin
      if (!open || !expect_mem || mem_seen) err($sformatf("unexpected memory request %08h we=%b", vif.mreq_addr, vif.mreq_we));
      else begin
        if (vif.mreq_addr !== {c_addr[31:5], 5'd0} || vif.mreq_we !== c_we) err("memory request address / direction wrong");
        if (c_we && (vif.mreq_wdata !== c_wdata || vif.mreq_wstrb !== c_strb)) err("write-through data / strobes wrong");
      end
      mem_seen = 1;
    end
    // invalidate: affects lines and a fill already in flight, not one starting in this cycle
    if (vif.invalidate) begin
      cov.sample(open && !c_we && !c_hit ? "invalidate_during_fill" : "invalidate_idle");
      if (open) discard = 1;
      for (int k = 0; k < SETS; k++) begin m_valid[k][0] = 0; m_valid[k][1] = 0; end
    end
    // new access
    if (vif.req_valid && vif.req_ready) begin
      bit [31:0] a = vif.req_addr;
      int ss = a[8:5];
      bit h0 = m_valid[ss][0] && m_tag[ss][0] == a[31:9];
      bit h1 = m_valid[ss][1] && m_tag[ss][1] == a[31:9];
      bit hit = (h0 || h1) && !vif.invalidate;
      if (open) err("access accepted while another is in progress");
      open = 1; c_addr = a; c_we = vif.req_we; c_wdata = vif.req_wdata; c_strb = vif.req_wstrb; c_hit = hit;
      discard = 0; mem_seen = 0;
      expect_mem = c_we || !hit;
      due = cyc + 1;
      if (hit) begin
        bit new_lru = h0 ? 1 : 0;
        if (m_lru[ss] != new_lru) cov.sample("lru_flip_on_hit");
        m_lru[ss] = new_lru;
        if (!c_we) begin
          n_hit++;
          cov.sample(h0 ? "read_hit_way0" : "read_hit_way1");
          if ({a[31:5], 5'd0} == last_write_line) cov.sample("read_after_write_hit");
        end
      end
      if (c_we) begin
        cov.sample(hit ? "write_hit" : "write_miss_no_allocate");
        if (c_strb != '1) cov.sample("partial_strobe");
        last_write_line = {a[31:5], 5'd0};
      end
    end
  endfunction
  function void check_phase(uvm_phase phase);
    if (open) err("access never answered");
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("accesses=%0d read hits=%0d errors=%0d", n, n_hit, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class l1_env extends uvm_env;
  `uvm_component_utils(l1_env)
  uvm_sequencer #(l1_item) sqr;
  l1_driver drv; l1_memory_responder memr; l1_checker chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = uvm_sequencer#(l1_item)::type_id::create("sqr", this);
    drv = l1_driver::type_id::create("drv", this);
    memr = l1_memory_responder::type_id::create("memr", this);
    chk = l1_checker::type_id::create("chk", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class l1_base_test extends uvm_test;
  `uvm_component_utils(l1_base_test)
  l1_env env; l1_config cfg; l1_memory mem; l1_vif_t vif;
  int n = 100;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = l1_config::type_id::create("cfg");
    mem = l1_memory::type_id::create("mem");
    knobs();
    uvm_config_db#(l1_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(l1_memory)::set(this, "env.*", "mem", mem);
    void'(uvm_config_db#(l1_vif_t)::get(this, "", "vif", vif));
    env = l1_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    l1_seq s = l1_seq::type_id::create("s");
    phase.raise_objection(this);
    s.n = n; s.cfg = cfg;
    s.start(env.sqr);
    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class l1_smoke_test extends l1_base_test;
  `uvm_component_utils(l1_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class l1_rand_test extends l1_base_test;
  `uvm_component_utils(l1_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 5000; endfunction
endclass
class l1_conflict_test extends l1_base_test;
  `uvm_component_utils(l1_conflict_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 4000; cfg.n_sets_used = 1; cfg.n_tags_used = 3; cfg.write_pct = 20; endfunction
endclass
class l1_invalidate_test extends l1_base_test;
  `uvm_component_utils(l1_invalidate_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 3000; cfg.inval_pct = 20; cfg.mem_max_lat = 15; endfunction
endclass
