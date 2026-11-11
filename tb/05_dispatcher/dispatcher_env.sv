class dispatcher_env extends uvm_env;
  `uvm_component_utils(dispatcher_env)
  uvm_sequencer #(disp_kernel) sqr;
  dispatcher_driver   drv;
  dispatcher_sm_model sm;
  dispatcher_checker  chk;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = uvm_sequencer#(disp_kernel)::type_id::create("sqr", this);
    drv = dispatcher_driver::type_id::create("drv", this);
    sm  = dispatcher_sm_model::type_id::create("sm", this);
    chk = dispatcher_checker::type_id::create("chk", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
