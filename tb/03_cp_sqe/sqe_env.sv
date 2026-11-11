class sqe_env extends uvm_env;
  `uvm_component_utils(sqe_env)
  uvm_sequencer #(sqe_op) sqr;
  sqe_op_driver    drv;
  sqe_gpu_model    gpu;
  sqe_memory_model memm;
  sqe_monitor      mon;
  sqe_scoreboard   sb;
  sqe_coverage     cov;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr  = uvm_sequencer#(sqe_op)::type_id::create("sqr", this);
    drv  = sqe_op_driver::type_id::create("drv", this);
    gpu  = sqe_gpu_model::type_id::create("gpu", this);
    memm = sqe_memory_model::type_id::create("memm", this);
    mon  = sqe_monitor::type_id::create("mon", this);
    sb   = sqe_scoreboard::type_id::create("sb", this);
    cov  = sqe_coverage::type_id::create("cov", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
    mon.op_ap.connect(sb.op_imp);
    mon.ev_ap.connect(sb.ev_imp);
    gpu.work_ap.connect(sb.work_imp);
    mon.op_ap.connect(cov.op_imp);
    mon.ev_ap.connect(cov.ev_imp);
  endfunction
endclass
