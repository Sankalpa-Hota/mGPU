// Every issue is checked against what must be true:
//   - the warp is alive and not waiting for a control instruction
//   - is_pc is the warp's current pc and is_instr is the program's instruction at that pc (nothing skipped,
//     nothing issued twice, nothing from a stale buffer)
//   - no source or destination register is still pending (RAW / WAW); EXIT only with nothing pending
// plus: no warp that stays eligible is passed over more than NW times (round-robin fairness).
class ws_checker extends uvm_component;
  `uvm_component_utils(ws_checker)
  ws_vif_t vif; ws_program prog;
  mgpu_coverage cov;
  bit [15:0] pend[4];
  bit        waiting[4];
  int        passed_over[4];
  int        n_issue, n_err;
  int        last_warp = -1;
  string names[$] = '{"issue_warp0", "issue_warp1", "issue_warp2", "issue_warp3", "raw_stall", "waw_stall",
                      "exit_waits_for_pending", "ctrl_wait", "all_four_eligible", "issue_backpressure",
                      "fetch_backpressure", "two_writebacks_same_cycle", "three_writebacks_same_cycle",
                      "same_warp_back_to_back", "relaunch"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("warp_scheduler");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(ws_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(ws_program)::get(this, "", "prog", prog));
  endfunction
  function void err(string s);
    n_err++;
    `uvm_error("CHK", s)
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      step();
    end
  endtask

  function void step();
    bit [15:0] cleared[4];
    if (vif.elig == 4'hF) cov.sample("all_four_eligible");
    if (vif.is_valid && !vif.is_ready) cov.sample("issue_backpressure");
    if (vif.f_valid && !vif.f_ready) cov.sample("fetch_backpressure");
    if ($countones(vif.wb_valid) == 2) cov.sample("two_writebacks_same_cycle");
    if ($countones(vif.wb_valid) == 3) cov.sample("three_writebacks_same_cycle");
    for (int w = 0; w < 4; w++) begin
      if (vif.wl_mask[w]) begin pend[w] = 0; waiting[w] = 0; passed_over[w] = 0; cov.sample("relaunch"); end
      if (vif.ctrl_done[w]) waiting[w] = 0;
    end
    for (int k = 0; k < 3; k++) if (vif.wb_valid[k]) cleared[vif.wb_warp[k]][vif.wb_rd[k]] = 1;

    // hazard coverage from the scheduler's own buffers (white box)
    for (int w = 0; w < 4; w++)
      if (vif.live[w] && tb_top.dut.ibuf_v[w] && !waiting[w] && !vif.elig[w]) begin
        bit [31:0] i = tb_top.dut.ibuf_instr[w];
        if (f_op(i) == OP_EXIT) cov.sample("exit_waits_for_pending");
        else if (writes_rd(i) && pend[w][f_rd(i)]) cov.sample("waw_stall");
        else cov.sample("raw_stall");
      end
    for (int w = 0; w < 4; w++) if (waiting[w]) cov.sample("ctrl_wait");

    if (vif.is_valid && vif.is_ready) begin
      int w = vif.is_warp;
      bit [31:0] i = vif.is_instr;
      n_issue++;
      cov.sample($sformatf("issue_warp%0d", w));
      if (w == last_warp) cov.sample("same_warp_back_to_back");
      last_warp = w;
      if (!vif.live[w]) err($sformatf("issue from dead warp %0d", w));
      if (waiting[w]) err($sformatf("warp %0d issued while waiting for a control instruction", w));
      if (vif.is_pc !== vif.pc[w]) err($sformatf("warp %0d issued pc %08h but its pc is %08h", w, vif.is_pc, vif.pc[w]));
      if (i !== prog.instr(vif.is_pc)) err($sformatf("warp %0d pc %08h: issued %08h, program has %08h", w, vif.is_pc, i, prog.instr(vif.is_pc)));
      if (uses_a(i) && pend[w][f_rs1(i)]) err($sformatf("RAW hazard: warp %0d issued %08h while r%0d pending", w, i, f_rs1(i)));
      if (uses_b(i) && pend[w][src_b(i)]) err($sformatf("RAW hazard: warp %0d issued %08h while r%0d pending", w, i, src_b(i)));
      if (writes_rd(i) && pend[w][f_rd(i)]) err($sformatf("WAW hazard: warp %0d issued %08h while r%0d pending", w, i, f_rd(i)));
      if (f_op(i) == OP_EXIT && pend[w] != 0) err($sformatf("warp %0d EXIT issued with pending writes %h", w, pend[w]));
      if (unit_of(f_op(i)) == U_CTRL) waiting[w] = 1;
      for (int o = 0; o < 4; o++)
        if (o != w && vif.elig[o]) begin
          passed_over[o]++;
          if (passed_over[o] > 4) err($sformatf("warp %0d eligible but passed over %0d times (starvation)", o, passed_over[o]));
        end
      passed_over[w] = 0;
    end
    for (int w = 0; w < 4; w++) begin
      pend[w] &= ~cleared[w];
      if (!vif.elig[w]) passed_over[w] = 0;
    end
    if (vif.is_valid && vif.is_ready && writes_rd(vif.is_instr)) pend[vif.is_warp][f_rd(vif.is_instr)] = 1;
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("instructions issued=%0d errors=%0d", n_issue, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass
