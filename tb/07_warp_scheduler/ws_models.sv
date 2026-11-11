// Plays the instruction cache: one fetch at a time, random readiness and latency.
class ws_fetch_model extends uvm_component;
  `uvm_component_utils(ws_fetch_model)
  ws_vif_t vif; ws_config cfg; ws_program prog;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(ws_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(ws_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(ws_program)::get(this, "", "prog", prog));
  endfunction
  task run_phase(uvm_phase phase);
    vif.f_ready = 0; vif.f_rsp_valid = 0; vif.f_rsp_instr = 0;
    forever begin
      bit [31:0] a;
      @(posedge vif.clk); #1;
      vif.f_ready = ($urandom_range(99) < cfg.fetch_rdy_pct);
      @(negedge vif.clk);
      if (!(vif.f_valid && vif.f_ready)) continue;
      a = vif.f_pc;
      @(posedge vif.clk); #1;
      vif.f_ready = 0;
      repeat ($urandom_range(cfg.fetch_max_lat, 0)) @(posedge vif.clk);
      #1; vif.f_rsp_valid = 1; vif.f_rsp_instr = prog.instr(a);
      @(posedge vif.clk); #1; vif.f_rsp_valid = 0;
    end
  endtask
endclass

// Plays the SIMT stack: owns pc and live for each warp. Advance = pc + 4 at the next edge. A control
// instruction is resolved after a random delay: EXIT kills the warp, anything else jumps to a random pc.
// Dead warps are relaunched at a random pc after a short pause.
class ws_simt_model extends uvm_component;
  `uvm_component_utils(ws_simt_model)
  ws_vif_t vif; ws_config cfg;
  int n_launch, n_exit;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(ws_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(ws_config)::get(this, "", "cfg", cfg));
  endfunction
  task resolve(int w, bit is_exit);
    repeat ($urandom_range(cfg.ctrl_max_lat, 1)) @(posedge vif.clk);
    #1;
    vif.ctrl_done[w] = 1;
    if (cfg.stop) is_exit = 1;   // draining: every control instruction ends the warp (programs may loop forever)
    if (is_exit) begin vif.live[w] = 0; n_exit++; end
    else vif.pc[w] = $urandom_range(255) * 4;
    @(posedge vif.clk); #1;
    vif.ctrl_done[w] = 0;
  endtask
  task run_phase(uvm_phase phase);
    int dead_for[4];
    vif.wl_mask = 0; vif.live = 0; vif.ctrl_done = 0;
    for (int w = 0; w < 4; w++) vif.pc[w] = 0;
    wait (vif.rst_n === 1);
    forever begin
      bit [3:0] adv;
      @(negedge vif.clk);
      adv = vif.adv_mask;
      if (vif.is_valid && vif.is_ready && unit_of(f_op(vif.is_instr)) == U_CTRL) begin
        int w = vif.is_warp;
        bit ex = f_op(vif.is_instr) == OP_EXIT;
        fork resolve(w, ex); join_none
      end
      @(posedge vif.clk); #1;
      vif.wl_mask = 0;
      for (int w = 0; w < 4; w++) begin
        if (adv[w]) vif.pc[w] = vif.pc[w] + 4;
        if (!vif.live[w]) begin
          dead_for[w]++;
          if (!cfg.stop && dead_for[w] > $urandom_range(6, 1)) begin
            vif.wl_mask[w] = 1; vif.live[w] = 1; vif.pc[w] = $urandom_range(255) * 4;
            dead_for[w] = 0; n_launch++;
          end
        end
      end
    end
  endtask
endclass

// Plays the execution units: readiness of the operand collector, and a writeback for every issued instruction
// that writes a register. ALU results come back fast, SFU and LSU results slowly, so completions are out of order.
class ws_exec_model extends uvm_component;
  `uvm_component_utils(ws_exec_model)
  ws_vif_t vif; ws_config cfg;
  typedef struct { int due; int warp; int rd; } wb_t;
  wb_t q[3][$];
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(ws_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(ws_config)::get(this, "", "cfg", cfg));
  endfunction
  task run_phase(uvm_phase phase);
    int cyc = 0;
    vif.is_ready = 0; vif.wb_valid = 0;
    forever begin
      @(negedge vif.clk);
      cyc++;
      if (vif.is_valid && vif.is_ready && writes_rd(vif.is_instr)) begin
        unit_e u = unit_of(f_op(vif.is_instr));
        int port = (u == U_SFU) ? 1 : (u == U_LSU) ? 2 : 0;
        int lat = (port == 0) ? $urandom_range(cfg.alu_lat, 1) : (port == 1) ? $urandom_range(cfg.sfu_max_lat, 4) : $urandom_range(cfg.lsu_max_lat, 2);
        wb_t e; e.due = cyc + lat; e.warp = vif.is_warp; e.rd = f_rd(vif.is_instr);
        q[port].push_back(e);
      end
      @(posedge vif.clk); #1;
      vif.is_ready = ($urandom_range(99) < cfg.issue_rdy_pct);
      vif.wb_valid = 0;
      for (int p = 0; p < 3; p++) begin
        int k = -1;
        foreach (q[p][i]) if (k < 0 && q[p][i].due <= cyc) k = i;
        if (k >= 0) begin
          vif.wb_valid[p] = 1; vif.wb_warp[p] = q[p][k].warp; vif.wb_rd[p] = q[p][k].rd;
          q[p].delete(k);
        end
      end
    end
  endtask
  function bit empty();
    return q[0].size() == 0 && q[1].size() == 0 && q[2].size() == 0;
  endfunction
endclass
