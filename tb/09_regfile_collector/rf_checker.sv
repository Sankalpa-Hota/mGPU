// Cycle checker with a full model of the register file.
//  - every dispatched instruction is the one that was issued (in order: the collector has one entry)
//  - it goes to the right unit, and its operand values equal the model (r0 = 0)
//  - it is offered exactly 1 cycle after acceptance, or 2 if both operands are in the same bank
//  - writeback arbitration: per bank the lowest-numbered port wins, every other free bank is granted
//  - writes change only the lanes in the mask; a launch clears the warp's registers
class rf_checker extends uvm_component;
  `uvm_component_utils(rf_checker)
  rf_vif_t vif;
  mgpu_coverage cov;
  bit [31:0] m[4][16][8];
  bit        exp_open;
  bit [1:0]  e_warp;
  bit [31:0] e_instr, e_pc;
  bit [7:0]  e_mask;
  int        e_due, cyc, n_ex, n_wb, n_err;
  bit        offered;
  string names[$] = '{"unit_alu", "unit_sfu", "unit_lsu", "unit_barrier", "bank_conflict", "no_operands",
                      "r0_operand", "wb_same_bank_collision", "three_writes_one_cycle", "wb_partial_mask", "wb_to_r0",
                      "launch_clear", "ex_backpressure", "issue_back_to_back"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("regfile_collector");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(rf_vif_t)::get(this, "", "vif", vif));
  endfunction
  function void err(string s);
    n_err++;
    `uvm_error("CHK", s)
  endfunction
  function bit [1:0] bank(bit [1:0] w, bit [3:0] r); return 2'(r + w); endfunction
  function int unit_for(bit [31:0] i);
    case (unit_of(f_op(i)))
      U_SFU: return 1;
      U_LSU: return 2;
      default: return f_op(i) == OP_BAR ? 3 : 0;
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
    bit [3:0] taken = 0;
    bit       fire = 0;
    // dispatch
    if (vif.ex_valid) begin
      if (!exp_open) err("ex_valid with no instruction in the collector");
      else begin
        if (!offered) begin
          if (cyc != e_due) err($sformatf("instruction %08h offered at cycle %0d, expected %0d", e_instr, cyc, e_due));
          offered = 1;
          if (vif.ex_warp !== e_warp || vif.ex_instr !== e_instr || vif.ex_pc !== e_pc || vif.ex_mask !== e_mask)
            err($sformatf("dispatched warp %0d %08h, issued warp %0d %08h", vif.ex_warp, vif.ex_instr, e_warp, e_instr));
          if (vif.ex_unit != unit_for(e_instr)) err($sformatf("%08h sent to unit %0d, expected %0d", e_instr, vif.ex_unit, unit_for(e_instr)));
          for (int l = 0; l < 8; l++) begin
            bit [31:0] ea = uses_a(e_instr) ? m[e_warp][f_rs1(e_instr)][l] : 0;
            bit [31:0] eb = uses_b(e_instr) ? m[e_warp][src_b(e_instr)][l] : 0;
            if (vif.ex_a[l] !== ea) err($sformatf("%08h lane %0d operand A %08h, expected %08h (r%0d)", e_instr, l, vif.ex_a[l], ea, f_rs1(e_instr)));
            if (vif.ex_b[l] !== eb) err($sformatf("%08h lane %0d operand B %08h, expected %08h (r%0d)", e_instr, l, vif.ex_b[l], eb, src_b(e_instr)));
          end
        end
        if (vif.ex_ready[vif.ex_unit]) begin
          fire = 1; exp_open = 0; n_ex++;
          case (vif.ex_unit)
            0: cov.sample("unit_alu");
            1: cov.sample("unit_sfu");
            2: cov.sample("unit_lsu");
            default: cov.sample("unit_barrier");
          endcase
        end else cov.sample("ex_backpressure");
      end
    end else if (exp_open && cyc >= e_due) err($sformatf("instruction %08h not offered by cycle %0d", e_instr, e_due));

    // writeback arbitration
    for (int k = 0; k < 3; k++) begin
      bit [1:0] b = bank(vif.wb_warp[k], vif.wb_rd[k]);
      bit exp_rdy = vif.wb_valid[k] && !taken[b];
      if (vif.wb_valid[k] && taken[b]) cov.sample("wb_same_bank_collision");
      if (vif.wb_ready[k] !== exp_rdy) err($sformatf("wb port %0d ready=%b expected %b", k, vif.wb_ready[k], exp_rdy));
      if (exp_rdy) taken[b] = 1;
    end
    if ((vif.wb_valid & vif.wb_ready) == 3'b111) cov.sample("three_writes_one_cycle");
    for (int k = 0; k < 3; k++)
      if (vif.wb_valid[k] && vif.wb_ready[k]) begin
        n_wb++;
        if (vif.wb_mask[k] != 8'hFF) cov.sample("wb_partial_mask");
        if (vif.wb_rd[k] == 0) cov.sample("wb_to_r0");
        else for (int l = 0; l < 8; l++) if (vif.wb_mask[k][l]) m[vif.wb_warp[k]][vif.wb_rd[k]][l] = vif.wb_data[k][l];
      end
    for (int w = 0; w < 4; w++)
      if (vif.wl_mask[w]) begin
        cov.sample("launch_clear");
        for (int r = 0; r < 16; r++) for (int l = 0; l < 8; l++) m[w][r][l] = 0;
      end

    // acceptance
    if (vif.is_valid && vif.is_ready) begin
      bit [31:0] i = vif.is_instr;
      bit conflict = uses_a(i) && uses_b(i) && bank(vif.is_warp, f_rs1(i)) == bank(vif.is_warp, src_b(i));
      if (exp_open && !fire) err("instruction accepted while the collector is full");
      if (fire) cov.sample("issue_back_to_back");
      if (conflict) cov.sample("bank_conflict");
      if (!uses_a(i) && !uses_b(i)) cov.sample("no_operands");
      if ((uses_a(i) && f_rs1(i) == 0) || (uses_b(i) && src_b(i) == 0)) cov.sample("r0_operand");
      exp_open = 1; offered = 0;
      e_warp = vif.is_warp; e_instr = i; e_pc = vif.is_pc; e_mask = vif.is_mask;
      e_due = cyc + ((uses_a(i) || uses_b(i)) ? (conflict ? 3 : 2) : 1);   // read in the next cycle, offer in the one after
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("dispatched=%0d writes=%0d errors=%0d", n_ex, n_wb, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass
