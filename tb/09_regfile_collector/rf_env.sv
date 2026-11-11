class rf_env extends uvm_env;
  `uvm_component_utils(rf_env)
  rf_issue_driver iss;
  rf_wb_driver    wb[3];
  rf_exec_sink    sink;
  rf_checker      chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    iss  = rf_issue_driver::type_id::create("iss", this);
    for (int k = 0; k < 3; k++) begin
      wb[k] = rf_wb_driver::type_id::create($sformatf("wb%0d", k), this);
      wb[k].port = k;
    end
    sink = rf_exec_sink::type_id::create("sink", this);
    chk  = rf_checker::type_id::create("chk", this);
  endfunction
endclass
