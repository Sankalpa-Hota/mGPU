typedef virtual alu_interface alu_vif_t;
import mgpu_pkg::*;

class alu_config extends uvm_object;
  `uvm_object_utils(alu_config)
  int wb_rdy_pct = 80;
  function new(string name = "alu_config"); super.new(name); endfunction
endclass

class alu_item extends uvm_sequence_item;
  `uvm_object_utils(alu_item)
  rand bit [5:0]  op;
  rand bit [3:0]  rd, rs1, rs2;
  rand bit [17:0] imm;
  rand bit [1:0]  warp;
  rand bit [7:0]  mask;
  rand bit [31:0] wg_id, arg;
  rand bit [2:0]  nwarps;
  rand int        kind;             // operand style: 0 random, 1 corner values, 2 equal pairs (branches)
  bit [31:0] a[8], b[8];
  bit [31:0] pc;
  int        gap;
  constraint c_op  { op inside {OP_NOP, OP_ADD, OP_SUB, OP_MUL, OP_AND, OP_OR, OP_XOR, OP_SHL, OP_SHR, OP_SLT,
                                OP_ADDI, OP_LUI, OP_S2R, OP_BEQ, OP_BNE, OP_JMP, OP_EXIT}; }
  constraint c_nw  { nwarps inside {[1:4]}; }
  constraint c_s2r { op == OP_S2R -> imm < 7; }
  constraint c_k   { kind inside {[0:2]}; }
  function new(string name = "alu_item"); super.new(name); endfunction
  function bit [31:0] corner();
    bit [31:0] v[$] = '{0, 1, 32'hFFFF_FFFF, 32'h8000_0000, 32'h7FFF_FFFF, 31, 32, 33, 64};
    return v[$urandom_range(v.size() - 1)];
  endfunction
  function void post_randomize();
    for (int l = 0; l < 8; l++) begin
      a[l] = (kind == 1) ? corner() : $urandom;
      b[l] = (kind == 1) ? corner() : (kind == 2 && $urandom_range(1)) ? a[l] : $urandom;
      if (op inside {OP_SHL, OP_SHR} && kind == 0) b[l] = $urandom_range(40);
    end
    pc = $urandom & ~3;
    gap = $urandom_range(3) == 0 ? $urandom_range(3) : 0;
  endfunction
  function bit [31:0] instr();
    return (op inside {OP_ADDI, OP_LUI, OP_S2R}) ? {op, rd, rs1, imm} : {op, rd, rs1, rs2, imm[13:0]};
  endfunction
endclass

class alu_seq extends uvm_sequence #(alu_item);
  `uvm_object_utils(alu_seq)
  int n = 200;
  function new(string name = "alu_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      alu_item it = alu_item::type_id::create("it");
      start_item(it);
      if (!it.randomize()) `uvm_fatal("RAND", "alu item")
      finish_item(it);
    end
  endtask
endclass

class alu_driver extends uvm_driver #(alu_item);
  `uvm_component_utils(alu_driver)
  alu_vif_t vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(alu_vif_t)::get(this, "", "vif", vif));
  endfunction
  task run_phase(uvm_phase phase);
    vif.ex_valid = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.gap) begin @(posedge vif.clk); #1; end
      vif.ex_valid = 1; vif.ex_warp = req.warp; vif.ex_instr = req.instr(); vif.ex_pc = req.pc; vif.ex_mask = req.mask;
      for (int l = 0; l < 8; l++) begin vif.ex_a[l] = req.a[l]; vif.ex_b[l] = req.b[l]; end
      vif.ctx_wg_id = req.wg_id; vif.ctx_nwarps = req.nwarps; vif.ctx_arg = req.arg;
      do @(negedge vif.clk); while (!vif.ex_ready);
      @(posedge vif.clk); #1;
      vif.ex_valid = 0;
      seq_item_port.item_done();
    end
  endtask
endclass

class alu_wb_sink extends uvm_component;
  `uvm_component_utils(alu_wb_sink)
  alu_vif_t vif; alu_config cfg;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(alu_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(alu_config)::get(this, "", "cfg", cfg));
  endfunction
  task run_phase(uvm_phase phase);
    vif.wb_ready = 0;
    forever begin @(posedge vif.clk); #1; vif.wb_ready = ($urandom_range(99) < cfg.wb_rdy_pct); end
  endtask
endclass

// Reference model, written from the ISA table, plus in-order checking of both outputs.
class alu_checker extends uvm_component;
  `uvm_component_utils(alu_checker)
  alu_vif_t vif;
  mgpu_coverage cov;
  typedef struct { bit [1:0] warp; bit [3:0] rd; bit [7:0] mask; bit [31:0] d[8]; int due; bit [31:0] instr; } wb_t;
  typedef struct { bit [1:0] warp; bit [31:0] instr, pc; bit [7:0] taken; int due; } br_t;
  wb_t wq[$];
  br_t bq[$];
  int cyc, n_wb, n_br, n_err;
  bit wb_seen_first;
  string names[$] = '{"op_ADD", "op_SUB", "op_MUL", "op_AND", "op_OR", "op_XOR", "op_SHL", "op_SHR", "op_SLT", "op_ADDI",
                      "op_LUI", "op_S2R", "s2r_lane", "s2r_warp", "s2r_wg", "s2r_tid", "s2r_arg", "s2r_undefined",
                      "tid_nwarps_1", "tid_nwarps_4", "br_beq", "br_bne", "br_all_taken", "br_none_taken", "br_some_taken",
                      "br_jmp", "br_exit", "nop_no_writeback", "rd_r0_no_writeback", "add_overflow", "slt_negative",
                      "shift_32_or_more", "partial_mask", "wb_backpressure"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("alu");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(alu_vif_t)::get(this, "", "vif", vif));
  endfunction
  function void err(string s); n_err++; `uvm_error("CHK", s) endfunction

  function bit [31:0] ref_op(bit [31:0] i, bit [31:0] a, bit [31:0] b, int lane, int w, bit [31:0] wg, int nw, bit [31:0] arg);
    int sa, sb;
    sa = a; sb = b;
    case (f_op(i))
      OP_ADD: return a + b;
      OP_SUB: return a - b;
      OP_MUL: return a * b;
      OP_AND: return a & b;
      OP_OR:  return a | b;
      OP_XOR: return a ^ b;
      OP_SHL: return a << (b % 32);
      OP_SHR: return a >> (b % 32);
      OP_SLT: return (sa < sb) ? 1 : 0;
      OP_ADDI: return a + {{14{i[17]}}, i[17:0]};
      OP_LUI: return {{14{i[17]}}, i[17:0]} << 14;
      OP_S2R: case (i[17:0])
        0: return lane;
        1: return w;
        2: return wg;
        3: return (wg * nw + w) * 8 + lane;
        4: return arg;
        default: return 0;
      endcase
      default: return 0;
    endcase
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      cyc++;
      step();
    end
  endtask

  function void step();
    // outputs
    if (vif.br_valid) begin
      if (bq.size() == 0) err("unexpected branch result");
      else begin
        br_t e = bq.pop_front();
        n_br++;
        if (cyc != e.due) err($sformatf("branch result at cycle %0d, due %0d", cyc, e.due));
        if (vif.br_warp !== e.warp || vif.br_instr !== e.instr || vif.br_pc !== e.pc || vif.br_taken !== e.taken)
          err($sformatf("branch %08h: taken %b, expected %b", e.instr, vif.br_taken, e.taken));
      end
    end
    if (vif.wb_valid) begin
      if (wq.size() == 0) err("unexpected writeback");
      else begin
        wb_t e = wq[0];
        if (!wb_seen_first && cyc != e.due) err($sformatf("writeback of %08h at cycle %0d, due %0d", e.instr, cyc, e.due));
        wb_seen_first = 1;
        if (!vif.wb_ready) cov.sample("wb_backpressure");
        else begin
          void'(wq.pop_front());
          wb_seen_first = 0;
          n_wb++;
          if (vif.wb_warp !== e.warp || vif.wb_rd !== e.rd || vif.wb_mask !== e.mask)
            err($sformatf("writeback of %08h: warp %0d r%0d mask %b, expected warp %0d r%0d mask %b", e.instr,
                          vif.wb_warp, vif.wb_rd, vif.wb_mask, e.warp, e.rd, e.mask));
          for (int l = 0; l < 8; l++)
            if (vif.wb_data[l] !== e.d[l]) err($sformatf("%08h lane %0d: result %08h, expected %08h", e.instr, l, vif.wb_data[l], e.d[l]));
        end
      end
    end
    // inputs
    if (vif.ex_valid && vif.ex_ready) predict();
  endfunction

  function void predict();
    bit [31:0] i = vif.ex_instr;
    bit [5:0] o = f_op(i);
    if (vif.ex_mask != 8'hFF) cov.sample("partial_mask");
    if (unit_of(o) == U_CTRL) begin
      br_t e;
      e.warp = vif.ex_warp; e.instr = i; e.pc = vif.ex_pc; e.due = cyc + 1; e.taken = 0;
      for (int l = 0; l < 8; l++) e.taken[l] = (o == OP_BNE) ? (vif.ex_a[l] != vif.ex_b[l]) : (vif.ex_a[l] == vif.ex_b[l]);
      bq.push_back(e);
      if (o == OP_BEQ || o == OP_BNE) begin
        bit [7:0] t = e.taken & vif.ex_mask;
        cov.sample(o == OP_BEQ ? "br_beq" : "br_bne");
        cov.sample(t == vif.ex_mask ? "br_all_taken" : t == 0 ? "br_none_taken" : "br_some_taken");
      end else cov.sample(o == OP_JMP ? "br_jmp" : "br_exit");
      return;
    end
    if (o == OP_NOP) begin cov.sample("nop_no_writeback"); return; end
    if (f_rd(i) == 0) begin cov.sample("rd_r0_no_writeback"); return; end
    begin
      wb_t e;
      e.warp = vif.ex_warp; e.rd = f_rd(i); e.mask = vif.ex_mask; e.instr = i;
      e.due = cyc + 1 + (wq.size() != 0 ? 1000 : 0);    // only the first in the queue has a fixed due cycle
      for (int l = 0; l < 8; l++)
        e.d[l] = ref_op(i, vif.ex_a[l], vif.ex_b[l], l, vif.ex_warp, vif.ctx_wg_id, vif.ctx_nwarps, vif.ctx_arg);
      wq.push_back(e);
      case (o)
        OP_ADD:  cov.sample("op_ADD");
        OP_SUB:  cov.sample("op_SUB");
        OP_MUL:  cov.sample("op_MUL");
        OP_AND:  cov.sample("op_AND");
        OP_OR:   cov.sample("op_OR");
        OP_XOR:  cov.sample("op_XOR");
        OP_SHL:  cov.sample("op_SHL");
        OP_SHR:  cov.sample("op_SHR");
        OP_SLT:  cov.sample("op_SLT");
        OP_ADDI: cov.sample("op_ADDI");
        OP_LUI:  cov.sample("op_LUI");
        default: cov.sample("op_S2R");
      endcase
      for (int l = 0; l < 8; l++) begin
        if (o == OP_ADD && {1'b0, vif.ex_a[l]} + {1'b0, vif.ex_b[l]} > 33'hFFFF_FFFF) cov.sample("add_overflow");
        if (o == OP_SLT && vif.ex_a[l][31] != vif.ex_b[l][31]) cov.sample("slt_negative");
        if ((o == OP_SHL || o == OP_SHR) && vif.ex_b[l] >= 32) cov.sample("shift_32_or_more");
      end
      if (o == OP_S2R) begin
        int k = i[17:0];
        cov.sample(k == 0 ? "s2r_lane" : k == 1 ? "s2r_warp" : k == 2 ? "s2r_wg" : k == 3 ? "s2r_tid" : k == 4 ? "s2r_arg" : "s2r_undefined");
        if (k == 3 && vif.ctx_nwarps == 1) cov.sample("tid_nwarps_1");
        if (k == 3 && vif.ctx_nwarps == 4) cov.sample("tid_nwarps_4");
      end
    end
  endfunction

  function void check_phase(uvm_phase phase);
    if (wq.size() != 0 || bq.size() != 0) err($sformatf("%0d results never came out", wq.size() + bq.size()));
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("writebacks=%0d branches=%0d errors=%0d", n_wb, n_br, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class alu_env extends uvm_env;
  `uvm_component_utils(alu_env)
  uvm_sequencer #(alu_item) sqr;
  alu_driver drv; alu_wb_sink sink; alu_checker chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = uvm_sequencer#(alu_item)::type_id::create("sqr", this);
    drv = alu_driver::type_id::create("drv", this);
    sink = alu_wb_sink::type_id::create("sink", this);
    chk = alu_checker::type_id::create("chk", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class alu_base_test extends uvm_test;
  `uvm_component_utils(alu_base_test)
  alu_env env; alu_config cfg; alu_vif_t vif;
  int n = 100;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = alu_config::type_id::create("cfg");
    knobs();
    uvm_config_db#(alu_config)::set(this, "env.*", "cfg", cfg);
    void'(uvm_config_db#(alu_vif_t)::get(this, "", "vif", vif));
    env = alu_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    alu_seq s = alu_seq::type_id::create("s");
    phase.raise_objection(this);
    s.n = n;
    s.start(env.sqr);
    cfg.wb_rdy_pct = 100;
    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass

class alu_smoke_test extends alu_base_test;
  `uvm_component_utils(alu_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class alu_rand_test extends alu_base_test;
  `uvm_component_utils(alu_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 5000; endfunction
endclass
class alu_backpressure_test extends alu_base_test;
  `uvm_component_utils(alu_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 3000; cfg.wb_rdy_pct = 20; endfunction
endclass
