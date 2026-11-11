// Plays the rest of the GPU: read pointer, fence pulses, error flags, busy bits, progress pulses, perf events.
class rbbm_hw_driver extends uvm_component;
  `uvm_component_utils(rbbm_hw_driver)
  rbbm_vif_t vif;
  rbbm_config cfg;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(rbbm_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(rbbm_config)::get(this, "", "cfg", cfg));
  endfunction
  function bit chance(int pct);
    return $urandom_range(99) < pct;
  endfunction
  task run_phase(uvm_phase phase);
    vif.ring_rptr = 0; vif.ev_fence = 0; vif.ev_bad_pkt = 0; vif.ev_bad_op = 0;
    vif.busy_in = 0; vif.progress = 0; vif.perf_ev = 0;
    forever begin
      @(posedge vif.clk); #1;
      if (cfg.hw_quiet) begin
        vif.ev_fence = 0; vif.progress = 0; vif.perf_ev = 0; vif.busy_in = 0;
        continue;
      end
      if (chance(20)) vif.ring_rptr = vif.ring_rptr + 1;
      vif.ev_fence = chance(cfg.fence_pct);
      if (chance(cfg.flag_pct)) vif.ev_bad_pkt = !vif.ev_bad_pkt;
      if (chance(cfg.flag_pct)) vif.ev_bad_op  = !vif.ev_bad_op;
      if (chance(cfg.busy_pct)) vif.busy_in = chance(30) ? 8'h00 : 8'($urandom);
      vif.progress = chance(cfg.progress_pct);
      for (int i = 0; i < 16; i++) vif.perf_ev[i] = chance(cfg.perf_pct);
    end
  endtask
endclass
