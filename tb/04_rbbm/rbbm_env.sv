class rbbm_env extends uvm_env;
  `uvm_component_utils(rbbm_env)
  rbbm_apb_agent       apb;
  rbbm_hw_driver       hw;
  rbbm_reference_model model;
  rbbm_reg_block       rm;
  rbbm_reg_adapter     adapter;
  uvm_reg_predictor #(apb_item) predictor;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    apb   = rbbm_apb_agent::type_id::create("apb", this);
    hw    = rbbm_hw_driver::type_id::create("hw", this);
    model = rbbm_reference_model::type_id::create("model", this);
    rm    = rbbm_reg_block::type_id::create("rm");
    rm.build();
    rm.reset();   // the mirror starts at the documented reset values, like the hardware
    adapter   = rbbm_reg_adapter::type_id::create("adapter");
    predictor = uvm_reg_predictor#(apb_item)::type_id::create("predictor", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    rm.default_map.set_sequencer(apb.sqr, adapter);
    rm.default_map.set_auto_predict(0);
    predictor.map = rm.default_map;
    predictor.adapter = adapter;
    apb.mon.ap.connect(predictor.bus_in);
  endfunction
endclass
