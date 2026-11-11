// Plays one sub-core's fetch unit: one outstanding fetch at a time, consecutive pcs within a stream.
class icache_fetch_driver extends uvm_driver #(icache_fetch);
  `uvm_component_utils(icache_fetch_driver)
  icache_vif_t vif;
  icache_config cfg;
  int port;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(icache_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(icache_config)::get(this, "", "cfg", cfg));
  endfunction
  task run_phase(uvm_phase phase);
    vif.req_valid[port] = 0; vif.req_pc[port] = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.gap) begin @(posedge vif.clk); #1; end
      for (int i = 0; i < req.len; i++) begin
        while (cfg.pause) begin @(posedge vif.clk); #1; end
        vif.req_valid[port] = 1;
        vif.req_pc[port] = req.pc + 4 * i;
        do @(negedge vif.clk); while (!vif.req_ready[port]);
        @(posedge vif.clk); #1;
        vif.req_valid[port] = 0;
        while (!vif.rsp_valid[port]) begin @(negedge vif.clk); if (!vif.rsp_valid[port]) @(posedge vif.clk); end
        @(posedge vif.clk); #1;
      end
      seq_item_port.item_done();
    end
  endtask
endclass
