typedef virtual rbbm_interface rbbm_vif_t;

class rbbm_config extends uvm_object;
  `uvm_object_utils(rbbm_config)
  bit hw_quiet      = 0;    // 1: hardware inputs held still (register-only tests)
  int fence_pct     = 3;    // chance per cycle of a fence pulse
  int flag_pct      = 1;    // chance per cycle that a bad_pkt / bad_op level toggles
  int busy_pct      = 50;   // chance per cycle that busy bits change
  int progress_pct  = 30;   // chance per cycle of a progress pulse
  int perf_pct      = 50;   // chance per cycle that each perf event is high
  function new(string name = "rbbm_config");
    super.new(name);
  endfunction
endclass
