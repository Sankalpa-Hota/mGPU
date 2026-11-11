typedef virtual dispatcher_interface disp_vif_t;
localparam int NSLOT = 4;
localparam int NSM   = 2;

class dispatcher_config extends uvm_object;
  `uvm_object_utils(dispatcher_config)
  int run_min = 5, run_max = 40;   // cycles a workgroup occupies its sub-core
  int sleep_pct = 0;               // chance per cycle that an awake SM goes to sleep (power gating)
  int wake_pct  = 30;              // chance per cycle that a sleeping SM wakes up
  function new(string name = "dispatcher_config");
    super.new(name);
  endfunction
endclass
