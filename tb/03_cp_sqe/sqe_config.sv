typedef virtual sqe_interface sqe_vif_t;
localparam int SETTLE = 3;

class sqe_config extends uvm_object;
  `uvm_object_utils(sqe_config)
  int disp_rdy_pct  = 100;  // dispatcher readiness
  int work_min      = 1;    // cycles a dispatched job keeps busy[0] high
  int work_max      = 20;
  int busy_delay_max = SETTLE; // how late busy[0] may rise after a dispatch (contract: at most SETTLE)
  int bg_busy_pct   = 0;    // chance per cycle that a background busy bit (1..7) starts a job
  int mem_rdy_pct   = 100;
  int ack_min       = 0;
  int ack_max       = 4;
  int op_gap_max    = 2;
  function new(string name = "sqe_config");
    super.new(name);
  endfunction
endclass
