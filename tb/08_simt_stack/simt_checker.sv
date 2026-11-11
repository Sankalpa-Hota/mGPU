// Two independent checks.
// 1. Semantics: each lane, run alone through the program with the same branch decisions, gives a trace of
//    pcs. The lanes' traces seen through the DUT (every step whose mask includes the lane) must equal them.
// 2. Reconvergence: a golden PDOM stack fed with the same steps must show the same pc and mask as the DUT
//    before every step. Wrong order or a missing pop keeps per-lane semantics but breaks this check.
class simt_checker extends uvm_component;
  `uvm_component_utils(simt_checker)
  uvm_analysis_imp #(simt_step, simt_checker) step_imp;
  simt_vif_t vif;
  simt_program prog;
  simt_decider dec;
  mgpu_coverage cov;
  bit [31:0] trace[4][8][$];
  // golden stacks
  bit [31:0] g_pc[4][$], g_rpc[4][$];
  bit [7:0]  g_mask[4][$];
  bit        g_overflow;
  int        n_steps, n_err, n_lanes_checked;
  bit        check_traces = 1;
  string names[$] = '{"uniform_taken", "uniform_not_taken", "divergent", "depth_3", "depth_5", "depth_7",
                      "loop_divergence", "exit_partial", "exit_whole_warp", "jmp", "target_is_join", "reuse_top",
                      "four_warps_live", "overflow"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("simt_stack");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    step_imp = new("step_imp", this);
    void'(uvm_config_db#(simt_vif_t)::get(this, "", "vif", vif));
  endfunction
  function void err(string s);
    n_err++;
    `uvm_error("CHK", s)
  endfunction

  function void launch();
    for (int w = 0; w < 4; w++) begin
      for (int l = 0; l < 8; l++) trace[w][l].delete();
      g_pc[w] = '{0}; g_rpc[w] = '{32'hFFFF_FFFF}; g_mask[w] = '{8'hFF};
    end
  endfunction

  function void pop_check(int w, ref int pops);
    while (g_pc[w].size() != 0 && g_pc[w][$] == g_rpc[w][$]) begin
      void'(g_pc[w].pop_back()); void'(g_rpc[w].pop_back()); void'(g_mask[w].pop_back());
      pops++;
    end
  endfunction

  function void write(simt_step s);
    int w = s.warp, top, pops = 0;
    n_steps++;
    if (vif.overflow !== g_overflow) err($sformatf("overflow flag %b, golden %b", vif.overflow, g_overflow));
    if (vif.live == 4'hF) cov.sample("four_warps_live");
    if (g_pc[w].size() == 0) begin err($sformatf("warp %0d executes but the golden stack is empty", w)); return; end
    top = g_pc[w].size() - 1;
    if (!g_overflow && (s.pc !== g_pc[w][top] || s.mask !== g_mask[w][top]))
      err($sformatf("warp %0d: DUT pc=%08h mask=%b, golden pc=%08h mask=%b (depth %0d)", w, s.pc, s.mask, g_pc[w][top], g_mask[w][top], top + 1));
    for (int l = 0; l < 8; l++) if (s.mask[l]) trace[w][l].push_back(s.pc);

    case (f_op(s.instr))
      OP_BEQ, OP_BNE: begin
        bit [7:0] act = g_mask[w][top], tk = s.taken & act;
        bit [31:0] tgt = s.pc + (f_target(s.instr) << 2), fall = s.pc + 4, jn = s.pc + (f_join(s.instr) << 2);
        if (tk == act) begin g_pc[w][top] = tgt; cov.sample("uniform_taken"); end
        else if (tk == 0) begin g_pc[w][top] = fall; cov.sample("uniform_not_taken"); end
        else begin
          bit need_fall = (fall != jn), need_tgt = (tgt != jn), reuse = (g_rpc[w][top] == jn);
          int after = g_pc[w].size() - reuse + need_fall + need_tgt;
          if (after > DEPTH) begin g_overflow = 1; g_pc[w][top] = tgt; cov.sample("overflow"); end
          else begin
            cov.sample("divergent");
            if ($signed(f_target(s.instr)) < 0) cov.sample("loop_divergence");
            if (!need_tgt) cov.sample("target_is_join");
            if (reuse) begin void'(g_pc[w].pop_back()); void'(g_rpc[w].pop_back()); void'(g_mask[w].pop_back()); cov.sample("reuse_top"); end
            else g_pc[w][top] = jn;
            if (need_fall) begin g_pc[w].push_back(fall); g_mask[w].push_back(act & ~tk); g_rpc[w].push_back(jn); end
            if (need_tgt)  begin g_pc[w].push_back(tgt);  g_mask[w].push_back(tk);       g_rpc[w].push_back(jn); end
            if (g_pc[w].size() >= 3) cov.sample("depth_3");
            if (g_pc[w].size() >= 5) cov.sample("depth_5");
            if (g_pc[w].size() >= 7) cov.sample("depth_7");
          end
        end
        pop_check(w, pops);
      end
      OP_JMP: begin g_pc[w][top] = s.pc + (f_target(s.instr) << 2); cov.sample("jmp"); pop_check(w, pops); end
      OP_EXIT: begin
        bit [7:0] act = g_mask[w][top];
        foreach (g_mask[w][k]) g_mask[w][k] &= ~act;
        while (g_mask[w].size() != 0 && g_mask[w][$] == 0) begin
          void'(g_pc[w].pop_back()); void'(g_rpc[w].pop_back()); void'(g_mask[w].pop_back());
        end
        if (g_pc[w].size() == 0) begin cov.sample("exit_whole_warp"); finish_warp(w); end
        else cov.sample("exit_partial");
      end
      default: begin g_pc[w][top] = s.pc + 4; pop_check(w, pops); end
    endcase
  endfunction

  // run every lane alone through the program and compare with what the DUT executed for it
  function void finish_warp(int w);
    if (!check_traces || g_overflow) return;
    for (int l = 0; l < 8; l++) begin
      bit [31:0] pc = 0;
      int visits[bit [31:0]];
      int n = 0;
      bit ok = 1;
      forever begin
        bit [31:0] ins = prog.at(pc);
        if (n >= trace[w][l].size() || trace[w][l][n] !== pc) begin
          err($sformatf("warp %0d lane %0d step %0d: DUT executed %s, lane alone executes %08h", w, l, n,
                        n < trace[w][l].size() ? $sformatf("%08h", trace[w][l][n]) : "nothing", pc));
          ok = 0;
          break;
        end
        n++;
        case (f_op(ins))
          OP_EXIT: break;
          OP_JMP: pc = pc + (f_target(ins) << 2);
          OP_BEQ, OP_BNE: begin
            int v = visits.exists(pc) ? visits[pc] : 0;
            visits[pc] = v + 1;
            pc = dec.taken(pc, ins, l, v) ? pc + (f_target(ins) << 2) : pc + 4;
          end
          default: pc = pc + 4;
        endcase
      end
      if (ok && n != trace[w][l].size()) err($sformatf("warp %0d lane %0d executed %0d extra instructions after its EXIT", w, l, trace[w][l].size() - n));
      n_lanes_checked++;
    end
  endfunction


  function void check_phase(uvm_phase phase);
    if (vif.live != 0) err("warps still live at the end");
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("steps=%0d lane traces checked=%0d errors=%0d", n_steps, n_lanes_checked, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class simt_launch_sub extends uvm_subscriber #(int);
  `uvm_component_utils(simt_launch_sub)
  simt_checker chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void write(int t); chk.launch(); endfunction
endclass
