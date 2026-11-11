// Cycle checker with a model of the cache contents (tags + valid bits), so it knows whether every request
// must hit or miss. Checks: returned instruction; hit answered exactly one cycle later; a miss produces exactly
// one line fill for the right line and nothing else does; round-robin fairness between the two ports.
class icache_checker extends uvm_component;
  `uvm_component_utils(icache_checker)
  icache_vif_t vif;
  icache_memory mem;
  mgpu_coverage cov;
  bit [31:0] m_tag[LINES];
  bit        m_valid[LINES];
  bit [31:0] out_pc[2];
  int        out_due[2];      // cycle the answer is due for a hit (-1 = waiting for a miss)
  bit        outstanding[2];
  bit        miss_open, fill_seen, discard;
  bit [31:0] miss_pc;
  int        miss_port;
  bit        skipped[2];
  int        cyc, n_hit, n_miss, n_err;
  bit        was_valid_before_inval[LINES];

  string names[$] = '{"hit_port0", "hit_port1", "miss_port0", "miss_port1", "both_ports_request", "port_waits_during_miss",
                      "conflict_eviction", "invalidate_idle", "invalidate_during_miss", "miss_after_invalidate",
                      "index_first", "index_last", "same_line_back_to_back_other_port", "tag_alias_msb"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("icache");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(icache_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(icache_memory)::get(this, "", "mem", mem));
  endfunction
  function void err(string s);
    n_err++;
    `uvm_error("CHK", s)
  endfunction

  bit [31:0] last_line = '1;
  int        last_port = -1;

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      cyc++;
      step();
    end
  endtask

  function void step();
    // answers
    for (int p = 0; p < 2; p++)
      if (vif.rsp_valid[p]) begin
        if (!outstanding[p]) err($sformatf("answer on port %0d with no request", p));
        else begin
          bit [31:0] e = mem.word(out_pc[p]);
          if (vif.rsp_instr !== e) err($sformatf("port %0d pc %08h: instr %08h, expected %08h", p, out_pc[p], vif.rsp_instr, e));
          if (out_due[p] >= 0 && cyc != out_due[p]) err($sformatf("port %0d hit answered at cycle %0d, due %0d", p, cyc, out_due[p]));
          outstanding[p] = 0;
        end
      end
      else if (outstanding[p] && out_due[p] >= 0 && cyc > out_due[p]) begin
        err($sformatf("port %0d hit for pc %08h not answered next cycle", p, out_pc[p]));
        outstanding[p] = 0;
      end

    // fill completes (install mirrors the spec: not if invalidated meanwhile or in this cycle)
    if (miss_open && vif.mrsp_valid && fill_seen) begin
      int ix = miss_pc[8:5];
      if (!discard && !vif.invalidate) begin m_valid[ix] = 1; m_tag[ix] = miss_pc[31:9]; end
      miss_open = 0;
    end

    // line fill requests
    if (vif.mreq_valid && vif.mreq_ready) begin
      if (!miss_open || fill_seen) err($sformatf("unexpected line fill for %08h", vif.mreq_addr));
      else if (vif.mreq_addr !== {miss_pc[31:5], 5'd0}) err($sformatf("fill for %08h, the miss was for %08h", vif.mreq_addr, miss_pc));
      fill_seen = 1;
    end
    if (miss_open && vif.req_valid != 0) cov.sample("port_waits_during_miss");
    if (vif.req_valid == 2'b11) cov.sample("both_ports_request");

    // invalidate: affects misses already in flight, not one that starts in this same cycle
    if (vif.invalidate) begin
      cov.sample(miss_open ? "invalidate_during_miss" : "invalidate_idle");
      if (miss_open) discard = 1;
      foreach (m_valid[i]) begin was_valid_before_inval[i] = m_valid[i]; m_valid[i] = 0; end
    end

    // accepted requests
    for (int p = 0; p < 2; p++)
      if (vif.req_valid[p] && vif.req_ready[p]) begin
        bit [31:0] pc = vif.req_pc[p];
        int ix = pc[8:5];
        bit hit = m_valid[ix] && m_tag[ix] == pc[31:9] && !vif.invalidate;
        if (outstanding[p]) err($sformatf("port %0d accepted a second request", p));
        if (miss_open) err("request accepted while a miss is in progress (cache is blocking)");
        outstanding[p] = 1; out_pc[p] = pc;
        if (pc[31] && m_valid[ix] && m_tag[ix] == {1'b0, pc[30:9]}) cov.sample("tag_alias_msb");   // same line except the top bit
        if (ix == 0) cov.sample("index_first");
        if (ix == LINES - 1) cov.sample("index_last");
        if ({pc[31:5], 5'd0} == last_line && last_port != p) cov.sample("same_line_back_to_back_other_port");
        last_line = {pc[31:5], 5'd0}; last_port = p;
        if (hit) begin
          out_due[p] = cyc + 1; n_hit++;
          cov.sample($sformatf("hit_port%0d", p));
        end else begin
          out_due[p] = -1; n_miss++;
          cov.sample($sformatf("miss_port%0d", p));
          if (m_valid[ix]) cov.sample("conflict_eviction");
          if (was_valid_before_inval[ix]) begin cov.sample("miss_after_invalidate"); was_valid_before_inval[ix] = 0; end
          miss_open = 1; fill_seen = 0; discard = 0; miss_pc = pc; miss_port = p;
        end
        // fairness: the other port waited and lost; it must win next time
        if (vif.req_valid[1 - p]) begin
          if (skipped[1 - p]) err($sformatf("port %0d starved: skipped twice in a row", 1 - p));
          skipped[1 - p] = 1;
        end
        skipped[p] = 0;
      end

  endfunction

  function void check_phase(uvm_phase phase);
    if (outstanding[0] || outstanding[1]) err("request never answered");
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("hits=%0d misses=%0d errors=%0d", n_hit, n_miss, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass
