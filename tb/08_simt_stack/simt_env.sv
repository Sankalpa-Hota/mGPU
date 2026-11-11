class simt_env extends uvm_env;
  `uvm_component_utils(simt_env)
  simt_executor   exe;
  simt_checker    chk;
  simt_launch_sub ls;
  simt_program    prog;
  simt_decider    dec;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    exe = simt_executor::type_id::create("exe", this);
    chk = simt_checker::type_id::create("chk", this);
    ls  = simt_launch_sub::type_id::create("ls", this);
    prog = simt_program::type_id::create("prog");
    dec  = simt_decider::type_id::create("dec");
  endfunction
  function void connect_phase(uvm_phase phase);
    exe.prog = prog; exe.dec = dec; chk.prog = prog; chk.dec = dec; ls.chk = chk;
    exe.step_ap.connect(chk.step_imp);
    exe.launch_ap.connect(ls.analysis_export);
  endfunction
endclass
