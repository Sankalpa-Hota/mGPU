typedef virtual l2_interface l2_vif_t;
localparam int SETS = 32;
localparam int BANK = 1;

class l2_config extends uvm_object;
  `uvm_object_utils(l2_config)
  int mem_rdy_pct = 70, mem_max_lat = 10, write_pct = 45, full_pct = 20, sets_used = 4, tags_used = 4;
  bit [31:0] fault_line = 32'hFFFF_FFFF;   // a line whose memory reads answer with err
  function new(string name = "l2_config"); super.new(name); endfunction
endclass

class l2_dram extends uvm_object;
  `uvm_object_utils(l2_dram)
  bit [7:0] b[bit [31:0]];
  function new(string name = "l2_dram"); super.new(name); endfunction
  function bit [7:0] rd8(bit [31:0] a); return b.exists(a) ? b[a] : 8'(a ^ (a >> 7)); endfunction
  function bit [255:0] line(bit [31:0] a);
    for (int i = 0; i < 32; i++) line[8*i +: 8] = rd8({a[31:5], 5'd0} + i);
  endfunction
endclass

// line address with this bank's bank bit: set s, tag t
function automatic bit [31:0] l2_line(int s, int t);
  return (t << (5 + 1 + 5)) | (s << 6) | (BANK << 5);
endfunction

class l2_item extends uvm_sequence_item;
  `uvm_object_utils(l2_item)
  bit we; bit [31:0] addr, wstrb; bit [255:0] wdata; bit [1:0] id; int gap;
  function new(string name = "l2_item"); super.new(name); endfunction
endclass

class l2_seq extends uvm_sequence #(l2_item);
  `uvm_object_utils(l2_seq)
  int n = 200;
  l2_config cfg;
  function new(string name = "l2_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      l2_item it = l2_item::type_id::create("it");
      start_item(it);
      it.addr = l2_line($urandom_range(cfg.sets_used - 1), $urandom_range(cfg.tags_used - 1)) + 4 * $urandom_range(7);
      it.we = ($urandom_range(99) < cfg.write_pct) && ({it.addr[31:5], 5'd0} != cfg.fault_line);
      for (int i = 0; i < 8; i++) it.wdata[32*i +: 32] = $urandom;
      it.wstrb = ($urandom_range(99) < cfg.full_pct) ? '1 : $urandom;
      it.id = $urandom_range(3);
      it.gap = $urandom_range(2);
      finish_item(it);
    end
  endtask
endclass

class l2_driver extends uvm_driver #(l2_item);
  `uvm_component_utils(l2_driver)
  l2_vif_t vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(l2_vif_t)::get(this, "", "vif", vif));
  endfunction
  task run_phase(uvm_phase phase);
    vif.req_valid = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.gap) begin @(posedge vif.clk); #1; end
      vif.req_valid = 1; vif.req_addr = req.addr; vif.req_we = req.we; vif.req_wdata = req.wdata;
      vif.req_wstrb = req.wstrb; vif.req_id = req.id;
      do @(negedge vif.clk); while (!vif.req_ready);
      @(posedge vif.clk); #1;
      vif.req_valid = 0;
      while (!vif.rsp_valid) @(negedge vif.clk);
      @(posedge vif.clk); #1;
      seq_item_port.item_done();
    end
  endtask
endclass

class l2_dram_responder extends uvm_component;
  `uvm_component_utils(l2_dram_responder)
  l2_vif_t vif; l2_config cfg; l2_dram mem;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(l2_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(l2_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(l2_dram)::get(this, "", "mem", mem));
  endfunction
  task run_phase(uvm_phase phase);
    vif.mreq_ready = 0; vif.mrsp_valid = 0; vif.mrsp_err = 0;
    forever begin
      bit [31:0] a; bit we; bit [255:0] d;
      @(posedge vif.clk); #1;
      vif.mreq_ready = ($urandom_range(99) < cfg.mem_rdy_pct);
      @(negedge vif.clk);
      if (!(vif.mreq_valid && vif.mreq_ready)) continue;
      a = vif.mreq_addr; we = vif.mreq_we; d = vif.mreq_wdata;
      if (we) for (int i = 0; i < 32; i++) mem.b[a + i] = d[8*i +: 8];
      @(posedge vif.clk); #1;
      vif.mreq_ready = 0;
      repeat ($urandom_range(cfg.mem_max_lat)) @(posedge vif.clk);
      #1;
      vif.mrsp_err  = !we && (a == cfg.fault_line);
      vif.mrsp_data = (we || vif.mrsp_err) ? '0 : mem.line(a);
      vif.mrsp_valid = 1;
      @(posedge vif.clk); #1;
      vif.mrsp_valid = 0; vif.mrsp_err = 0;
    end
  endtask
endclass

// Golden flat memory + exact cache-state model: predicts every writeback and fill, checks every answer, and
// after a flush checks that DRAM holds exactly the golden contents.
class l2_checker extends uvm_component;
  `uvm_component_utils(l2_checker)
  l2_vif_t vif; l2_dram mem; l2_config cfg;
  mgpu_coverage cov;
  bit [7:0]  gold[bit [31:0]];
  bit [21:0] m_tag[SETS][2];
  bit        m_valid[SETS][2], m_dirty[SETS][2], m_lru[SETS];
  bit [255:0] m_data[SETS][2];
  typedef struct { bit [31:0] addr; bit we; bit [255:0] data; } mreq_t;
  mreq_t exp_q[$];
  bit open, flushing;
  bit c_we; bit [31:0] c_addr, c_strb; bit [255:0] c_wdata; bit [1:0] c_id;
  int n_rsp, n_err, n_flush;
  string names[$] = '{"read_hit", "read_miss_clean_victim", "read_miss_dirty_victim", "write_hit", "write_miss_full_no_fill",
                      "write_miss_partial_fill", "write_miss_dirty_victim", "flush_with_dirty_lines", "flush_all_clean",
                      "fault_read_not_installed", "memory_backpressure", "id_0", "id_1", "id_2", "id_3"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("l2_cache");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(l2_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(l2_dram)::get(this, "", "mem", mem));
    void'(uvm_config_db#(l2_config)::get(this, "", "cfg", cfg));
  endfunction
  function void err(string s); n_err++; `uvm_error("CHK", s) endfunction
  function bit [7:0] g8(bit [31:0] a); return gold.exists(a) ? gold[a] : 8'(a ^ (a >> 7)); endfunction
  function bit [255:0] gline(bit [31:0] a);
    for (int i = 0; i < 32; i++) gline[8*i +: 8] = g8({a[31:5], 5'd0} + i);
  endfunction
  function int set_of(bit [31:0] a); return a[10:6]; endfunction
  function bit [21:0] tag_of(bit [31:0] a); return a[31:11]; endfunction
  function bit [31:0] rebuild(int s, bit [21:0] t); return (t << 11) | (s << 6) | (BANK << 5); endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      if (vif.mreq_valid && !vif.mreq_ready) cov.sample("memory_backpressure");
      if (vif.mreq_valid && vif.mreq_ready) begin
        if (exp_q.size() == 0) err($sformatf("unexpected memory request %08h we=%b", vif.mreq_addr, vif.mreq_we));
        else begin
          mreq_t e = exp_q.pop_front();
          if (vif.mreq_addr !== e.addr || vif.mreq_we !== e.we) err($sformatf("memory request %08h we=%b, expected %08h we=%b", vif.mreq_addr, vif.mreq_we, e.addr, e.we));
          else if (e.we && vif.mreq_wdata !== e.data) err($sformatf("writeback of %08h carries wrong data", e.addr));
        end
      end
      if (vif.rsp_valid) begin
        n_rsp++;
        if (!open) err("answer with no request");
        else begin
          if (vif.rsp_id !== c_id) err($sformatf("answer id %0d, request id %0d", vif.rsp_id, c_id));
          if (!c_we) begin
            bit [255:0] e = ({c_addr[31:5], 5'd0} == cfg.fault_line) ? '0 : gline(c_addr);
            if (vif.rsp_data !== e) err($sformatf("read %08h returned wrong data", c_addr));
          end
          if (exp_q.size() != 0) err("answered before the expected memory traffic happened");
          open = 0;
        end
      end
      if (vif.flush_done) begin
        n_flush++;
        if (exp_q.size() != 0) err("flush finished before all dirty lines were written back");
        foreach (gold[a]) if (mem.rd8(a) !== gold[a]) begin err($sformatf("after flush DRAM[%08h] = %02h, expected %02h", a, mem.rd8(a), gold[a])); break; end
        flushing = 0;
      end
      if (vif.flush_req && !flushing && !open && !vif.busy) start_flush();
      if (vif.req_valid && vif.req_ready) accept();
    end
  endtask

  function void start_flush();
    bit any = 0;
    flushing = 1;
    for (int s = 0; s < SETS; s++) for (int w = 0; w < 2; w++)
      if (m_valid[s][w] && m_dirty[s][w]) begin
        mreq_t e; e.addr = rebuild(s, m_tag[s][w]); e.we = 1; e.data = m_data[s][w];
        exp_q.push_back(e); m_dirty[s][w] = 0; any = 1;
      end
    for (int s = 0; s < SETS; s++) for (int w = 0; w < 2; w++) m_valid[s][w] = 0;   // clean and invalidate
    cov.sample(any ? "flush_with_dirty_lines" : "flush_all_clean");
  endfunction

  function void accept();
    int s; bit [21:0] t; bit h0, h1;
    open = 1;
    c_we = vif.req_we; c_addr = vif.req_addr; c_strb = vif.req_wstrb; c_wdata = vif.req_wdata; c_id = vif.req_id;
    cov.sample($sformatf("id_%0d", c_id));
    s = set_of(c_addr); t = tag_of(c_addr);
    if (c_addr[5] != BANK) err("request for the other bank");
    h0 = m_valid[s][0] && m_tag[s][0] == t; h1 = m_valid[s][1] && m_tag[s][1] == t;
    if (h0 || h1) begin
      int w = h1;
      m_lru[s] = !w;
      if (c_we) begin
        for (int b = 0; b < 32; b++) if (c_strb[b]) m_data[s][w][8*b +: 8] = c_wdata[8*b +: 8];
        m_dirty[s][w] = 1;
        cov.sample("write_hit");
      end else cov.sample("read_hit");
    end else begin
      int w = m_lru[s];
      bit dirty_victim = m_valid[s][w] && m_dirty[s][w];
      bit full = c_we && c_strb == '1;
      bit fault = !full && ({c_addr[31:5], 5'd0} == cfg.fault_line);
      if (dirty_victim) begin
        mreq_t e; e.addr = rebuild(s, m_tag[s][w]); e.we = 1; e.data = m_data[s][w];
        exp_q.push_back(e);
      end
      if (!full) begin mreq_t e; e.addr = {c_addr[31:5], 5'd0}; e.we = 0; exp_q.push_back(e); end
      if (c_we) cov.sample(full ? "write_miss_full_no_fill" : "write_miss_partial_fill");
      if (c_we && dirty_victim) cov.sample("write_miss_dirty_victim");
      if (!c_we) cov.sample(dirty_victim ? "read_miss_dirty_victim" : "read_miss_clean_victim");
      if (fault) cov.sample("fault_read_not_installed");
      else begin
        if (dirty_victim) m_dirty[s][w] = 0;
        m_valid[s][w] = 1; m_tag[s][w] = t; m_dirty[s][w] = c_we; m_lru[s] = !w;
        m_data[s][w] = full ? '0 : gline(c_addr);
        if (c_we) for (int b = 0; b < 32; b++) if (c_strb[b]) m_data[s][w][8*b +: 8] = c_wdata[8*b +: 8];
      end
      if (fault && dirty_victim) m_dirty[s][w] = 0;
    end
    if (c_we) for (int b = 0; b < 32; b++) if (c_strb[b]) gold[{c_addr[31:5], 5'd0} + b] = c_wdata[8*b +: 8];
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("answers=%0d flushes=%0d errors=%0d", n_rsp, n_flush, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class l2_env extends uvm_env;
  `uvm_component_utils(l2_env)
  uvm_sequencer #(l2_item) sqr;
  l2_driver drv; l2_dram_responder dram; l2_checker chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = uvm_sequencer#(l2_item)::type_id::create("sqr", this);
    drv = l2_driver::type_id::create("drv", this);
    dram = l2_dram_responder::type_id::create("dram", this);
    chk = l2_checker::type_id::create("chk", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class l2_base_test extends uvm_test;
  `uvm_component_utils(l2_base_test)
  l2_env env; l2_config cfg; l2_dram mem; l2_vif_t vif;
  int n = 100, rounds = 1;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = l2_config::type_id::create("cfg");
    mem = l2_dram::type_id::create("mem");
    knobs();
    uvm_config_db#(l2_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(l2_dram)::set(this, "env.*", "mem", mem);
    void'(uvm_config_db#(l2_vif_t)::get(this, "", "vif", vif));
    env = l2_env::type_id::create("env", this);
  endfunction
  task flush();
    @(posedge vif.clk); #1;
    vif.flush_req = 1;
    while (!vif.flush_done) @(negedge vif.clk);
    @(posedge vif.clk); #1;
    vif.flush_req = 0;
  endtask
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    vif.flush_req = 0;
    repeat (rounds) begin
      l2_seq s = l2_seq::type_id::create("s");
      s.n = n; s.cfg = cfg;
      s.start(env.sqr);
      flush();
    end
    repeat (5) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class l2_smoke_test extends l2_base_test;
  `uvm_component_utils(l2_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class l2_rand_test extends l2_base_test;
  `uvm_component_utils(l2_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 800; rounds = 5; endfunction
endclass
class l2_eviction_test extends l2_base_test;
  `uvm_component_utils(l2_eviction_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 1000; rounds = 4; cfg.sets_used = 1; cfg.tags_used = 5; cfg.write_pct = 60; endfunction
endclass
// Like the CPU between kernels: after a flush, write new data straight into DRAM (and the golden memory).
// If the flush left any line cached, a later read returns the stale copy.
class l2_cpu_writes_test extends l2_base_test;
  `uvm_component_utils(l2_cpu_writes_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 400; rounds = 6; cfg.sets_used = 3; cfg.tags_used = 3; endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    vif.flush_req = 0;
    repeat (rounds) begin
      l2_seq s = l2_seq::type_id::create("s");
      s.n = n; s.cfg = cfg;
      s.start(env.sqr);
      flush();
      for (int k = 0; k < 64; k++) begin
        bit [31:0] a = l2_line($urandom_range(cfg.sets_used - 1), $urandom_range(cfg.tags_used - 1)) + $urandom_range(31);
        bit [7:0] v = $urandom;
        mem.b[a] = v; env.chk.gold[a] = v;
      end
    end
    phase.drop_objection(this);
  endtask
endclass

class l2_fault_test extends l2_base_test;
  `uvm_component_utils(l2_fault_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 600; rounds = 3; cfg.fault_line = l2_line(1, 2); cfg.sets_used = 2; cfg.tags_used = 3; endfunction
endclass
