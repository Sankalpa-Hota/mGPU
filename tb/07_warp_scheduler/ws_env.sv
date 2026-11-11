class ws_env extends uvm_env;
  `uvm_component_utils(ws_env)
  ws_fetch_model fetch;
  ws_simt_model  simt;
  ws_exec_model  exec;
  ws_checker     chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    fetch = ws_fetch_model::type_id::create("fetch", this);
    simt  = ws_simt_model::type_id::create("simt", this);
    exec  = ws_exec_model::type_id::create("exec", this);
    chk   = ws_checker::type_id::create("chk", this);
  endfunction
endclass
