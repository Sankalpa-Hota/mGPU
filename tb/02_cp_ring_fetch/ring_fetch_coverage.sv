`uvm_analysis_imp_decl(_cwptr)
`uvm_analysis_imp_decl(_creq)

// Transaction coverage (batches, requests) plus cycle coverage of internal conditions read from probe wires.
class ring_fetch_coverage extends uvm_component;
  `uvm_component_utils(ring_fetch_coverage)
  uvm_analysis_imp_cwptr #(ring_wptr_item, ring_fetch_coverage) wptr_imp;
  uvm_analysis_imp_creq  #(ring_req_item,  ring_fetch_coverage) req_imp;
  ring_vif_t vif;
  ring_fetch_config cfg;
  mgpu_coverage cov;
  string bin_names[$] = '{"batch_1", "batch_2_7", "batch_8", "batch_9_31", "batch_near_full",
                     "wptr_wrap", "wptr_moved_during_request",
                     "lat_short", "lat_mid", "lat_long",
                     "req_first_line", "req_last_line",
                     "out_stall", "fifo_full", "fetch_blocked_by_room", "ring_full_one_slot_free", "idle_empty"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("ring_fetch");
    foreach (bin_names[i]) cov.add_bin(bin_names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    wptr_imp = new("wptr_imp", this);
    req_imp  = new("req_imp", this);
    void'(uvm_config_db#(ring_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(ring_fetch_config)::get(this, "", "cfg", cfg));
  endfunction
  function void write_cwptr(ring_wptr_item w);
    int n = w.data.size();
    cov.sample(n == 1 ? "batch_1" : n < 8 ? "batch_2_7" : n == 8 ? "batch_8" : n < RING_SIZE - 4 ? "batch_9_31" : "batch_near_full");
    if (w.wrapped) cov.sample("wptr_wrap");
    if (w.req_in_flight) cov.sample("wptr_moved_during_request");
  endfunction
  function void write_creq(ring_req_item r);
    int line = (r.addr - cfg.ring_base) / 32;
    cov.sample(r.latency <= 2 ? "lat_short" : r.latency <= 6 ? "lat_mid" : "lat_long");
    if (line == 0) cov.sample("req_first_line");
    if (line == RING_SIZE / 8 - 1) cov.sample("req_last_line");
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      if (vif.dw_valid && !vif.dw_ready) cov.sample("out_stall");
      if (tb_top.dut.count == 16) cov.sample("fifo_full");
      if (tb_top.dut.state == 0 && tb_top.dut.avail != 0 && !tb_top.dut.room) cov.sample("fetch_blocked_by_room");
      if (RING_LOG2'(vif.wptr - vif.rptr) == RING_SIZE - 1) cov.sample("ring_full_one_slot_free");
      if (!vif.busy) cov.sample("idle_empty");
    end
  endtask
  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass
