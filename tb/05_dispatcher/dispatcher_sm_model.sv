// Plays the SMs and the GMU: each launched workgroup runs for a random time and then pulses wg_done for its
// slot; sm_avail models SMs being power gated and woken up.
class dispatcher_sm_model extends uvm_component;
  `uvm_component_utils(dispatcher_sm_model)
  disp_vif_t vif;
  dispatcher_config cfg;
  bit busy_slot[NSLOT];
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(disp_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(dispatcher_config)::get(this, "", "cfg", cfg));
  endfunction
  task run_wg(int s);
    @(posedge vif.clk);   // the launch edge itself: a workgroup can never finish in the cycle it starts
    repeat ($urandom_range(cfg.run_max, cfg.run_min)) @(posedge vif.clk);
    #1; vif.wg_done[s] = 1;
    @(posedge vif.clk); #1; vif.wg_done[s] = 0;
  endtask
  task run_phase(uvm_phase phase);
    vif.wg_done = 0; vif.sm_avail = '1;
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n === 1 && vif.launch_valid) begin
        int s = vif.launch_slot;
        fork run_wg(s); join_none
      end
      @(posedge vif.clk); #1;
      for (int m = 0; m < NSM; m++)
        if (vif.sm_avail[m]) begin if ($urandom_range(99) < cfg.sleep_pct) vif.sm_avail[m] = 0; end
        else if ($urandom_range(99) < cfg.wake_pct) vif.sm_avail[m] = 1;
    end
  endtask
endclass
