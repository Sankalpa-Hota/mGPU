class ring_fetch_env extends uvm_env;
  `uvm_component_utils(ring_fetch_env)
  uvm_sequencer #(ring_cmd)   sqr;
  ring_fetch_cpu_driver       cpu;
  ring_fetch_memory_responder memr;
  ring_fetch_sink             sink;
  ring_fetch_monitor          mon;
  ring_fetch_scoreboard       sb;
  ring_fetch_coverage         cov;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr  = uvm_sequencer#(ring_cmd)::type_id::create("sqr", this);
    cpu  = ring_fetch_cpu_driver::type_id::create("cpu", this);
    memr = ring_fetch_memory_responder::type_id::create("memr", this);
    sink = ring_fetch_sink::type_id::create("sink", this);
    mon  = ring_fetch_monitor::type_id::create("mon", this);
    sb   = ring_fetch_scoreboard::type_id::create("sb", this);
    cov  = ring_fetch_coverage::type_id::create("cov", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    cpu.seq_item_port.connect(sqr.seq_item_export);
    mon.wptr_ap.connect(sb.wptr_imp);
    mon.req_ap.connect(sb.req_imp);
    mon.dw_ap.connect(sb.dw_imp);
    mon.wptr_ap.connect(cov.wptr_imp);
    mon.req_ap.connect(cov.req_imp);
  endfunction
endclass
