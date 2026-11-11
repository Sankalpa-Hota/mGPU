// Plays the warp scheduler: offers random instructions, never reading a register with a write in flight.
class rf_issue_driver extends uvm_component;
  `uvm_component_utils(rf_issue_driver)
  rf_vif_t vif; rf_config cfg; rf_hazards hz;
  bit stop;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(rf_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(rf_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(rf_hazards)::get(this, "", "hz", hz));
  endfunction
  function bit [31:0] rand_instr();
    bit [5:0] ops[$] = '{OP_ADD, OP_SUB, OP_MUL, OP_ADDI, OP_LUI, OP_S2R, OP_DIV, OP_REM, OP_ISQRT, OP_LD, OP_ST,
                         OP_LDS, OP_STS, OP_BEQ, OP_BNE, OP_JMP, OP_BAR, OP_EXIT, OP_NOP, OP_XOR};
    bit [5:0] op = ops[$urandom_range(ops.size() - 1)];
    return {op, 4'($urandom_range(cfg.reg_span - 1)), 4'($urandom_range(cfg.reg_span - 1)),
            4'($urandom_range(cfg.reg_span - 1)), 14'($urandom)};
  endfunction
  function bit readable(int w, bit [31:0] i);
    if (uses_a(i) && hz.wb_inflight[w][f_rs1(i)] != 0) return 0;
    if (uses_b(i) && hz.wb_inflight[w][src_b(i)] != 0) return 0;
    return 1;
  endfunction
  task run_phase(uvm_phase phase);
    vif.is_valid = 0; vif.is_warp = 0; vif.is_instr = 0; vif.is_pc = 0; vif.is_mask = 0;
    wait (vif.rst_n === 1);
    forever begin
      @(posedge vif.clk); #1;
      if (vif.is_valid) begin
        // still waiting for is_ready? keep offering the same instruction
        if (!tb_top.accepted_last) continue;
        vif.is_valid = 0;
      end
      if (!stop && $urandom_range(99) < cfg.issue_pct) begin
        int w = $urandom_range(3);
        bit [31:0] i = rand_instr();
        if (readable(w, i) && !hz.busy_warp[w]) begin
          vif.is_valid = 1; vif.is_warp = w; vif.is_instr = i; vif.is_pc = $urandom & ~3; vif.is_mask = $urandom;
          if (uses_a(i)) hz.locked[w][f_rs1(i)] = 1;
          if (uses_b(i)) hz.locked[w][src_b(i)] = 1;
          hz.busy_warp[w] = 1;
        end
      end
    end
  endtask
endclass

// Plays one writeback source (ALU, SFU or LSU): random register writes with random lane masks.
class rf_wb_driver extends uvm_component;
  `uvm_component_utils(rf_wb_driver)
  rf_vif_t vif; rf_config cfg; rf_hazards hz;
  int port;
  bit stop;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(rf_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(rf_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(rf_hazards)::get(this, "", "hz", hz));
  endfunction
  task run_phase(uvm_phase phase);
    vif.wb_valid[port] = 0; vif.wb_warp[port] = 0; vif.wb_rd[port] = 0; vif.wb_mask[port] = 0;
    wait (vif.rst_n === 1);
    forever begin
      @(posedge vif.clk); #1;
      if (vif.wb_valid[port]) begin
        if (!tb_top.wb_accepted_last[port]) continue;
        hz.wb_inflight[vif.wb_warp[port]][vif.wb_rd[port]]--;
        vif.wb_valid[port] = 0;
      end
      if (!stop && $urandom_range(99) < cfg.wb_pct) begin
        int w = $urandom_range(3), r = $urandom_range(cfg.reg_span - 1);
        if (!hz.locked[w][r] && !hz.busy_warp[w]) begin
          vif.wb_valid[port] = 1; vif.wb_warp[port] = w; vif.wb_rd[port] = r;
          vif.wb_mask[port] = ($urandom_range(3) == 0) ? 8'hFF : $urandom;
          for (int l = 0; l < 8; l++) vif.wb_data[port][l] = $urandom;
          hz.wb_inflight[w][r]++;
        end
      end
    end
  endtask
endclass

// Plays the execution units: random readiness per unit; occasional warp launches (registers cleared).
class rf_exec_sink extends uvm_component;
  `uvm_component_utils(rf_exec_sink)
  rf_vif_t vif; rf_config cfg; rf_hazards hz;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(rf_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(rf_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(rf_hazards)::get(this, "", "hz", hz));
  endfunction
  task run_phase(uvm_phase phase);
    vif.ex_ready = 0; vif.wl_mask = 0;
    forever begin
      @(posedge vif.clk); #1;
      if (tb_top.ex_fired_last) begin
        hz.locked[tb_top.ex_fired_warp] = 0;
        hz.busy_warp[tb_top.ex_fired_warp] = 0;
      end
      for (int u = 0; u < 4; u++) vif.ex_ready[u] = ($urandom_range(99) < cfg.ex_rdy_pct);
      vif.wl_mask = 0;
      if ($urandom_range(99) < cfg.launch_pct) begin
        int w = $urandom_range(3);
        bit clean = !hz.busy_warp[w];
        for (int r = 0; r < 16; r++) if (hz.wb_inflight[w][r] != 0) clean = 0;
        if (clean) vif.wl_mask[w] = 1;
      end
    end
  endtask
endclass
