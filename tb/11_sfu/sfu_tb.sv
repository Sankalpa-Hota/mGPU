typedef virtual sfu_interface sfu_vif_t;
import mgpu_pkg::*;

class sfu_config extends uvm_object;
  `uvm_object_utils(sfu_config)
  int wb_rdy_pct = 80;
  function new(string name = "sfu_config"); super.new(name); endfunction
endclass

class sfu_item extends uvm_sequence_item;
  `uvm_object_utils(sfu_item)
  rand bit [5:0] op;
  rand bit [3:0] rd;
  rand bit [1:0] warp;
  rand bit [7:0] mask;
  rand int       kind;
  bit [31:0] a[8], b[8];
  int gap;
  constraint c_op { op inside {OP_DIV, OP_REM, OP_ISQRT}; }
  constraint c_k  { kind inside {[0:3]}; }
  function new(string name = "sfu_item"); super.new(name); endfunction
  function void post_randomize();
    for (int l = 0; l < 8; l++) begin
      bit [31:0] corners[$] = '{0, 1, 2, 3, 32'hFFFF_FFFF, 32'h8000_0000, 32'h7FFF_FFFF};
      case (kind)
        0: begin a[l] = $urandom; b[l] = $urandom; end
        1: begin a[l] = corners[$urandom_range(6)]; b[l] = corners[$urandom_range(6)]; end
        2: begin a[l] = $urandom; b[l] = $urandom_range(9); end                      // small divisors, includes 0
        default: begin                                                               // around perfect squares
          bit [31:0] s = $urandom_range(65535);
          a[l] = s * s + $urandom_range(2) - 1; b[l] = $urandom;
        end
      endcase
    end
    gap = $urandom_range(3) == 0 ? $urandom_range(5) : 0;
  endfunction
endclass

class sfu_seq extends uvm_sequence #(sfu_item);
  `uvm_object_utils(sfu_seq)
  int n = 100;
  function new(string name = "sfu_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      sfu_item it = sfu_item::type_id::create("it");
      start_item(it);
      if (!it.randomize()) `uvm_fatal("RAND", "sfu item")
      finish_item(it);
    end
  endtask
endclass

class sfu_driver extends uvm_driver #(sfu_item);
  `uvm_component_utils(sfu_driver)
  sfu_vif_t vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(sfu_vif_t)::get(this, "", "vif", vif));
  endfunction
  task run_phase(uvm_phase phase);
    vif.ex_valid = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.gap) begin @(posedge vif.clk); #1; end
      vif.ex_valid = 1; vif.ex_warp = req.warp; vif.ex_instr = {req.op, req.rd, 22'h0}; vif.ex_mask = req.mask;
      for (int l = 0; l < 8; l++) begin vif.ex_a[l] = req.a[l]; vif.ex_b[l] = req.b[l]; end
      do @(negedge vif.clk); while (!vif.ex_ready);
      @(posedge vif.clk); #1;
      vif.ex_valid = 0;
      seq_item_port.item_done();
    end
  endtask
endclass

class sfu_wb_sink extends uvm_component;
  `uvm_component_utils(sfu_wb_sink)
  sfu_vif_t vif; sfu_config cfg;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(sfu_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(sfu_config)::get(this, "", "cfg", cfg));
  endfunction
  task run_phase(uvm_phase phase);
    vif.wb_ready = 0;
    forever begin @(posedge vif.clk); #1; vif.wb_ready = ($urandom_range(99) < cfg.wb_rdy_pct); end
  endtask
endclass

// Reference: SystemVerilog's own / and % on unsigned values, divide-by-zero per the ISA table, and an
// integer square root found by checking r*r <= a < (r+1)*(r+1) in 64-bit arithmetic.
class sfu_checker extends uvm_component;
  `uvm_component_utils(sfu_checker)
  sfu_vif_t vif;
  mgpu_coverage cov;
  typedef struct { bit [5:0] op; bit [1:0] warp; bit [3:0] rd; bit [7:0] mask; bit [31:0] d[8]; int due; } exp_t;
  exp_t q[$];
  int cyc, n, n_err;
  bit first_seen;
  string names[$] = '{"op_DIV", "op_REM", "op_ISQRT", "div_by_zero", "rem_by_zero", "a_less_than_b", "a_max",
                      "isqrt_perfect_square", "isqrt_square_minus_1", "isqrt_zero", "isqrt_max", "partial_mask",
                      "wb_backpressure", "back_to_back"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("sfu");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(sfu_vif_t)::get(this, "", "vif", vif));
  endfunction
  function void err(string s); n_err++; `uvm_error("CHK", s) endfunction

  function bit [31:0] isqrt(bit [31:0] a);
    longint unsigned r = 0;
    for (int bitn = 15; bitn >= 0; bitn--) begin
      longint unsigned t = r | (64'd1 << bitn);
      if (t * t <= a) r = t;
    end
    return r;
  endfunction
  function bit [31:0] ref_op(bit [5:0] op, bit [31:0] a, bit [31:0] b);
    case (op)
      OP_DIV: return (b == 0) ? 32'hFFFF_FFFF : a / b;
      OP_REM: return (b == 0) ? a : a % b;
      default: return isqrt(a);
    endcase
  endfunction

  int last_accept = -10;
  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      cyc++;
      if (vif.wb_valid) begin
        if (q.size() == 0) err("unexpected result");
        else begin
          exp_t e = q[0];
          if (!first_seen && cyc != e.due) err($sformatf("result at cycle %0d, due %0d (latency)", cyc, e.due));
          first_seen = 1;
          if (!vif.wb_ready) cov.sample("wb_backpressure");
          else begin
            void'(q.pop_front()); first_seen = 0; n++;
            if (vif.wb_warp !== e.warp || vif.wb_rd !== e.rd || vif.wb_mask !== e.mask) err("result routing (warp / rd / mask) wrong");
            for (int l = 0; l < 8; l++)
              if (vif.wb_data[l] !== e.d[l]) err($sformatf("op %0h lane %0d: %08h, expected %08h", e.op, l, vif.wb_data[l], e.d[l]));
          end
        end
      end
      if (vif.ex_valid && vif.ex_ready) begin
        exp_t e;
        bit [5:0] op = f_op(vif.ex_instr);
        if (q.size() != 0) err("new instruction accepted while the previous result is still pending");
        if (cyc - last_accept <= ((op == OP_ISQRT) ? 18 : 34)) cov.sample("back_to_back");
        last_accept = cyc;
        e.op = op; e.warp = vif.ex_warp; e.rd = f_rd(vif.ex_instr); e.mask = vif.ex_mask;
        e.due = cyc + 1 + ((op == OP_ISQRT) ? 16 : 32);
        for (int l = 0; l < 8; l++) begin
          bit [31:0] a = vif.ex_a[l], b = vif.ex_b[l];
          e.d[l] = ref_op(op, a, b);
          if (op != OP_ISQRT && a < b) cov.sample("a_less_than_b");
          if (a == 32'hFFFF_FFFF) cov.sample("a_max");
          if (op == OP_DIV && b == 0) cov.sample("div_by_zero");
          if (op == OP_REM && b == 0) cov.sample("rem_by_zero");
          if (op == OP_ISQRT) begin
            bit [31:0] r = isqrt(a);
            if (a == 0) cov.sample("isqrt_zero");
            if (a == 32'hFFFF_FFFF) cov.sample("isqrt_max");
            if (r * r == a && a != 0) cov.sample("isqrt_perfect_square");
            if ((r + 1) * (r + 1) == a + 1) cov.sample("isqrt_square_minus_1");
          end
        end
        case (op) OP_DIV: cov.sample("op_DIV"); OP_REM: cov.sample("op_REM"); default: cov.sample("op_ISQRT"); endcase
        if (vif.ex_mask != 8'hFF) cov.sample("partial_mask");
        q.push_back(e);
      end
    end
  endtask
  function void check_phase(uvm_phase phase);
    if (q.size() != 0) err("result never came out");
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("results=%0d errors=%0d", n, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class sfu_env extends uvm_env;
  `uvm_component_utils(sfu_env)
  uvm_sequencer #(sfu_item) sqr;
  sfu_driver drv; sfu_wb_sink sink; sfu_checker chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = uvm_sequencer#(sfu_item)::type_id::create("sqr", this);
    drv = sfu_driver::type_id::create("drv", this);
    sink = sfu_wb_sink::type_id::create("sink", this);
    chk = sfu_checker::type_id::create("chk", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class sfu_base_test extends uvm_test;
  `uvm_component_utils(sfu_base_test)
  sfu_env env; sfu_config cfg; sfu_vif_t vif;
  int n = 50;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = sfu_config::type_id::create("cfg");
    knobs();
    uvm_config_db#(sfu_config)::set(this, "env.*", "cfg", cfg);
    void'(uvm_config_db#(sfu_vif_t)::get(this, "", "vif", vif));
    env = sfu_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    sfu_seq s = sfu_seq::type_id::create("s");
    phase.raise_objection(this);
    s.n = n;
    s.start(env.sqr);
    cfg.wb_rdy_pct = 100;
    while (vif.busy) @(posedge vif.clk);
    repeat (5) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class sfu_smoke_test extends sfu_base_test;
  `uvm_component_utils(sfu_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class sfu_rand_test extends sfu_base_test;
  `uvm_component_utils(sfu_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 2000; endfunction
endclass
class sfu_backpressure_test extends sfu_base_test;
  `uvm_component_utils(sfu_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 800; cfg.wb_rdy_pct = 10; endfunction
endclass
