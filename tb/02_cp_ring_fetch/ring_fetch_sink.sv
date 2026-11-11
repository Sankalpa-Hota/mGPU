// Plays the packet decoder: takes dwords with a random ready.
class ring_fetch_sink extends uvm_component;
  `uvm_component_utils(ring_fetch_sink)
  ring_vif_t vif;
  ring_fetch_config cfg;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(ring_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(ring_fetch_config)::get(this, "", "cfg", cfg));
  endfunction
  task run_phase(uvm_phase phase);
    vif.dw_ready = 0;
    forever begin
      @(posedge vif.clk); #1;
      vif.dw_ready = ($urandom_range(99) < cfg.sink_pct);
    end
  endtask
endclass
