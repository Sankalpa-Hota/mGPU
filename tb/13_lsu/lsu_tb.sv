typedef virtual lsu_interface lsu_vif_t;
import mgpu_pkg::*;

class lsu_config extends uvm_object;
  `uvm_object_utils(lsu_config)
  int mem_rdy_pct = 70, mem_max_lat = 6, sm_max_lat = 4, wb_rdy_pct = 80;
  function new(string name = "lsu_config"); super.new(name); endfunction
endclass

// Global memory and shared memory contents, shared by the responders and the checker.
class lsu_memory extends uvm_object;
  `uvm_object_utils(lsu_memory)
  bit [31:0] g[bit [31:0]];
  bit [31:0] s[128];
  function new(string name = "lsu_memory"); super.new(name); endfunction
  function bit [31:0] gread(bit [31:0] a);
    bit [31:0] w = {a[31:2], 2'b00};
    return g.exists(w) ? g[w] : (w * 32'h2545F491) ^ 32'hC0FFEE00;
  endfunction
endclass

class lsu_item extends uvm_sequence_item;
  `uvm_object_utils(lsu_item)
  rand bit [5:0]  op;
  rand bit [3:0]  rd;
  rand bit [1:0]  warp;
  rand bit [7:0]  mask;
  rand int        pattern;  // 0 coalesced 1 one line per lane 2 same word 3 random in 256 B 4 random anywhere 5 two lines
  rand bit [17:0] imm;
  bit [31:0] a[8], b[8];
  int gap;
  constraint c_op  { op inside {OP_LD, OP_ST, OP_LDS, OP_STS}; }
  constraint c_p   { pattern inside {[0:5]}; }
  constraint c_m   { mask dist {8'hFF :/ 50, 8'h00 :/ 3, [8'h01:8'hFE] :/ 47}; }
  constraint c_imm { imm dist {0 :/ 50, [1:16] :/ 25, [18'h3FFF0:18'h3FFFF] :/ 25}; }   // small positive and negative
  function new(string name = "lsu_item"); super.new(name); endfunction
  function void post_randomize();
    bit [31:0] base = ($urandom & 32'h0000_FFE0) + 32'h1000;
    int shift = $urandom_range(7) * 4;
    for (int l = 0; l < 8; l++) begin
      case (pattern)
        0: a[l] = base + 4 * l;
        1: a[l] = base + 32 * l + 4 * $urandom_range(7);
        2: a[l] = base;
        3: a[l] = base + 4 * $urandom_range(63);
        4: a[l] = $urandom;
        default: a[l] = base + shift + 4 * l;     // a warp access that straddles two lines
      endcase
      if (op == OP_LDS || op == OP_STS) a[l] = a[l] & 32'h1FC;
      b[l] = $urandom;
    end
    gap = $urandom_range(2);
  endfunction
  function bit [31:0] instr();
    return {op, rd, 4'h0, imm};      // I-type: 18-bit signed immediate in [17:0]
  endfunction
endclass

class lsu_seq extends uvm_sequence #(lsu_item);
  `uvm_object_utils(lsu_seq)
  int n = 200;
  function new(string name = "lsu_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      lsu_item it = lsu_item::type_id::create("it");
      start_item(it);
      if (!it.randomize()) `uvm_fatal("RAND", "lsu item")
      finish_item(it);
    end
  endtask
endclass

class lsu_driver extends uvm_driver #(lsu_item);
  `uvm_component_utils(lsu_driver)
  lsu_vif_t vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(lsu_vif_t)::get(this, "", "vif", vif));
  endfunction
  task run_phase(uvm_phase phase);
    vif.ex_valid = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.gap) begin @(posedge vif.clk); #1; end
      vif.ex_valid = 1; vif.ex_warp = req.warp; vif.ex_instr = req.instr(); vif.ex_mask = req.mask;
      for (int l = 0; l < 8; l++) begin vif.ex_a[l] = req.a[l]; vif.ex_b[l] = req.b[l]; end
      do @(negedge vif.clk); while (!vif.ex_ready);
      @(posedge vif.clk); #1;
      vif.ex_valid = 0;
      seq_item_port.item_done();
    end
  endtask
endclass

// Plays the L1 cache (line reads, strobed line writes with acknowledge), the shared memory and the
// register file's write port readiness.
class lsu_responders extends uvm_component;
  `uvm_component_utils(lsu_responders)
  lsu_vif_t vif; lsu_config cfg; lsu_memory mem;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(lsu_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(lsu_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(lsu_memory)::get(this, "", "mem", mem));
  endfunction
  task l1();
    vif.mreq_ready = 0; vif.mrsp_valid = 0; vif.mrsp_data = 0;
    forever begin
      bit [31:0] a, st; bit we; bit [255:0] wd;
      @(posedge vif.clk); #1;
      vif.mreq_ready = ($urandom_range(99) < cfg.mem_rdy_pct);
      @(negedge vif.clk);
      if (!(vif.mreq_valid && vif.mreq_ready)) continue;
      a = vif.mreq_addr; we = vif.mreq_we; wd = vif.mreq_wdata; st = vif.mreq_wstrb;
      @(posedge vif.clk); #1;
      vif.mreq_ready = 0;
      repeat ($urandom_range(cfg.mem_max_lat)) @(posedge vif.clk);
      #1;
      for (int i = 0; i < 8; i++) begin
        if (we) begin
          bit [31:0] w = mem.gread(a + 4 * i);
          for (int k = 0; k < 4; k++) if (st[4 * i + k]) w[8*k +: 8] = wd[32*i + 8*k +: 8];
          if (st[4*i +: 4] != 0) mem.g[a + 4 * i] = w;
        end
        vif.mrsp_data[32*i +: 32] = we ? 32'h0 : mem.gread(a + 4 * i);
      end
      vif.mrsp_valid = 1;
      @(posedge vif.clk); #1;
      vif.mrsp_valid = 0;
    end
  endtask
  task smem();
    vif.sm_ready = 0; vif.sm_rsp_valid = 0;
    forever begin
      bit we; bit [7:0] m; bit [31:0] a[8], d[8];
      @(posedge vif.clk); #1;
      vif.sm_ready = ($urandom_range(99) < 70);
      @(negedge vif.clk);
      if (!(vif.sm_valid && vif.sm_ready)) continue;
      we = vif.sm_we; m = vif.sm_mask;
      for (int l = 0; l < 8; l++) begin a[l] = vif.sm_addr[l]; d[l] = vif.sm_wdata[l]; end
      @(posedge vif.clk); #1;
      vif.sm_ready = 0;
      repeat ($urandom_range(cfg.sm_max_lat)) @(posedge vif.clk);
      #1;
      for (int l = 0; l < 8; l++) if (m[l]) begin
        if (we) mem.s[(a[l] >> 2) % 128] = d[l];
        else vif.sm_rsp_data[l] = mem.s[(a[l] >> 2) % 128];
      end
      vif.sm_rsp_valid = 1;
      @(posedge vif.clk); #1;
      vif.sm_rsp_valid = 0;
    end
  endtask
  task wb();
    vif.wb_ready = 0;
    forever begin @(posedge vif.clk); #1; vif.wb_ready = ($urandom_range(99) < cfg.wb_rdy_pct); end
  endtask
  task run_phase(uvm_phase phase);
    fork l1(); smem(); wb(); join
  endtask
endclass

// Predicts, at acceptance, the exact list of line requests (coalescing order: lowest pending lane first),
// their write data and strobes, and the loaded values; then checks requests and the writeback against it.
class lsu_checker extends uvm_component;
  `uvm_component_utils(lsu_checker)
  lsu_vif_t vif; lsu_memory mem;
  mgpu_coverage cov;
  typedef struct { bit [31:0] addr; bit we; bit [255:0] wdata; bit [31:0] wstrb; } req_t;
  req_t rq[$];
  bit open, is_load, is_shared, expect_wb;
  bit [31:0] e_data[8];
  bit [1:0] e_warp; bit [3:0] e_rd; bit [7:0] e_mask;
  bit [31:0] e_addr[8];
  int n_lines_exp, n_ops, n_err;
  string names[$] = '{"op_LD", "op_ST", "op_LDS", "op_STS", "lines_1", "lines_2", "lines_3_7", "lines_8", "lines_0_empty_mask",
                      "all_lanes_same_word", "store_same_word_two_lanes", "negative_offset", "l1_backpressure",
                      "wb_backpressure", "partial_mask"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("lsu");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(lsu_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(lsu_memory)::get(this, "", "mem", mem));
  endfunction
  function void err(string s); n_err++; `uvm_error("CHK", s) endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      if (vif.mreq_valid && !vif.mreq_ready) cov.sample("l1_backpressure");
      if (vif.wb_valid && !vif.wb_ready) cov.sample("wb_backpressure");
      if (vif.mreq_valid && vif.mreq_ready) begin
        if (rq.size() == 0) err($sformatf("unexpected line request %08h", vif.mreq_addr));
        else begin
          req_t e = rq.pop_front();
          if (vif.mreq_addr !== e.addr || vif.mreq_we !== e.we) err($sformatf("line request %08h we=%b, expected %08h we=%b", vif.mreq_addr, vif.mreq_we, e.addr, e.we));
          if (e.we && (vif.mreq_wstrb !== e.wstrb || vif.mreq_wdata !== e.wdata))
            err($sformatf("store to %08h: strobes %08h expected %08h, or data wrong", e.addr, vif.mreq_wstrb, e.wstrb));
        end
      end
      if (vif.sm_valid && vif.sm_ready) begin
        if (!is_shared || !open) err("unexpected shared memory request");
        else for (int l = 0; l < 8; l++) if (e_mask[l] && vif.sm_addr[l] !== e_addr[l]) err($sformatf("shared lane %0d address %08h, expected %08h", l, vif.sm_addr[l], e_addr[l]));
      end
      if (vif.wb_valid && vif.wb_ready) begin
        if (!expect_wb) err("unexpected writeback");
        else begin
          expect_wb = 0;
          if (vif.wb_warp !== e_warp || vif.wb_rd !== e_rd || vif.wb_mask !== e_mask) err("writeback routing wrong");
          if (!is_shared) for (int l = 0; l < 8; l++)
            if (e_mask[l] && vif.wb_data[l] !== e_data[l]) err($sformatf("load lane %0d (addr %08h) got %08h, expected %08h", l, e_addr[l], vif.wb_data[l], e_data[l]));
        end
      end
      if (open && !vif.busy && rq.size() == 0 && !expect_wb) begin
        open = 0;
        if (!is_shared && vif.last_lines != n_lines_exp) err($sformatf("%0d line requests, expected %0d", vif.last_lines, n_lines_exp));
      end
      if (vif.ex_valid && vif.ex_ready) accept();
    end
  endtask

  function void accept();
    bit [5:0] op = f_op(vif.ex_instr);
    bit [7:0] pend;
    bit [31:0] imm = f_imm(vif.ex_instr);
    if (open) err("new instruction accepted before the previous one finished");
    n_ops++;
    open = 1; rq.delete();
    is_load = (op == OP_LD || op == OP_LDS); is_shared = (op == OP_LDS || op == OP_STS);
    expect_wb = is_load;
    e_warp = vif.ex_warp; e_rd = f_rd(vif.ex_instr); e_mask = vif.ex_mask;
    if ($signed(imm) < 0) cov.sample("negative_offset");
    if (e_mask != 8'hFF && e_mask != 0) cov.sample("partial_mask");
    for (int l = 0; l < 8; l++) e_addr[l] = vif.ex_a[l] + imm;
    case (op) OP_LD: cov.sample("op_LD"); OP_ST: cov.sample("op_ST"); OP_LDS: cov.sample("op_LDS"); default: cov.sample("op_STS"); endcase
    begin
      bit same = (e_mask != 0);
      for (int l = 0; l < 8; l++) if (e_mask[l] && e_addr[l][31:2] != e_addr[0][31:2]) same = 0;
      if (same && e_mask == 8'hFF) cov.sample("all_lanes_same_word");
    end
    if (is_shared) return;
    pend = e_mask;
    n_lines_exp = 0;
    while (pend != 0) begin
      req_t r;
      int lo = 0;
      bit [26:0] ln;
      while (!pend[lo]) lo++;
      ln = e_addr[lo][31:5];
      r.addr = {ln, 5'd0}; r.we = (op == OP_ST); r.wdata = 0; r.wstrb = 0;
      for (int l = 0; l < 8; l++)
        if (pend[l] && e_addr[l][31:5] == ln) begin
          int wofs = e_addr[l][4:2];
          if (r.we) begin
            if (r.wstrb[4*wofs +: 4] != 0) cov.sample("store_same_word_two_lanes");
            r.wdata[32*wofs +: 32] = vif.ex_b[l]; r.wstrb[4*wofs +: 4] = 4'hF;
          end else e_data[l] = mem.gread(e_addr[l]);
          pend[l] = 0;
        end
      rq.push_back(r);
      n_lines_exp++;
    end
    cov.sample(n_lines_exp == 0 ? "lines_0_empty_mask" : n_lines_exp == 1 ? "lines_1" : n_lines_exp == 2 ? "lines_2" :
               n_lines_exp == 8 ? "lines_8" : "lines_3_7");
  endfunction

  function void check_phase(uvm_phase phase);
    if (open || rq.size() != 0 || expect_wb) err("memory instruction never finished");
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("memory instructions=%0d errors=%0d", n_ops, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class lsu_env extends uvm_env;
  `uvm_component_utils(lsu_env)
  uvm_sequencer #(lsu_item) sqr;
  lsu_driver drv; lsu_responders rsp; lsu_checker chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = uvm_sequencer#(lsu_item)::type_id::create("sqr", this);
    drv = lsu_driver::type_id::create("drv", this);
    rsp = lsu_responders::type_id::create("rsp", this);
    chk = lsu_checker::type_id::create("chk", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class lsu_base_test extends uvm_test;
  `uvm_component_utils(lsu_base_test)
  lsu_env env; lsu_config cfg; lsu_memory mem; lsu_vif_t vif;
  int n = 100;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = lsu_config::type_id::create("cfg");
    mem = lsu_memory::type_id::create("mem");
    knobs();
    uvm_config_db#(lsu_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(lsu_memory)::set(this, "env.*", "mem", mem);
    void'(uvm_config_db#(lsu_vif_t)::get(this, "", "vif", vif));
    env = lsu_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    lsu_seq s = lsu_seq::type_id::create("s");
    phase.raise_objection(this);
    s.n = n;
    s.start(env.sqr);
    cfg.wb_rdy_pct = 100;
    while (vif.busy) @(posedge vif.clk);
    repeat (5) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class lsu_smoke_test extends lsu_base_test;
  `uvm_component_utils(lsu_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class lsu_rand_test extends lsu_base_test;
  `uvm_component_utils(lsu_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 3000; endfunction
endclass
class lsu_slow_memory_test extends lsu_base_test;
  `uvm_component_utils(lsu_slow_memory_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 1000; cfg.mem_rdy_pct = 25; cfg.mem_max_lat = 20; cfg.wb_rdy_pct = 30; endfunction
endclass
