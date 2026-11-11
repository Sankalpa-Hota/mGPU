// Drives the dword stream (one packet = header then payload) and, in parallel, the downstream out_ready.
class cp_driver extends uvm_driver #(cp_pkt);
  `uvm_component_utils(cp_driver)
  virtual cp_if vif;
  cp_cfg cfg;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual cp_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "no vif")
    if (!uvm_config_db#(cp_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "no cfg")
  endfunction

  task send_dw(bit [31:0] d);
    vif.dw_valid = 1;
    vif.dw_data  = d;
    do @(negedge vif.clk); while (!vif.dw_ready);
    @(posedge vif.clk); #1;
    vif.dw_valid = 0;
    vif.dw_data  = 'x;
  endtask

  task drive_ready();
    forever begin
      @(posedge vif.clk); #1;
      vif.out_ready = ($urandom_range(99) < cfg.ready_pct);
    end
  endtask

  task run_phase(uvm_phase phase);
    vif.dw_valid  = 0;
    vif.dw_data   = 'x;
    vif.out_ready = 1;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    fork drive_ready(); join_none
    forever begin
      seq_item_port.get_next_item(req);
      `uvm_info("DRV", req.convert2string(), UVM_HIGH)
      repeat (req.gap) begin @(posedge vif.clk); #1; end
      send_dw(req.header());
      foreach (req.payload[i]) send_dw(req.payload[i]);
      seq_item_port.item_done();
    end
  endtask
endclass
