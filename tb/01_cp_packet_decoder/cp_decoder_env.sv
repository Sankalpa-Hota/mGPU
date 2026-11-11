class cp_env extends uvm_env;
  `uvm_component_utils(cp_env)
  cp_agent      agt;
  cp_ref_model  model;
  cp_scoreboard sb;
  cp_decoder_coverage   cov;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agt   = cp_agent::type_id::create("agt", this);
    model = cp_ref_model::type_id::create("model", this);
    sb    = cp_scoreboard::type_id::create("sb", this);
    cov   = cp_decoder_coverage::type_id::create("cov", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    agt.mon.in_ap.connect(model.in_imp);
    agt.mon.out_ap.connect(sb.act_imp);
    model.exp_ap.connect(sb.exp_imp);
    model.pkt_ap.connect(cov.analysis_export);
  endfunction
endclass
