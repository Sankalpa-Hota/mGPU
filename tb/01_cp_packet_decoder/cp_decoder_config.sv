class cp_cfg extends uvm_object;
  `uvm_object_utils(cp_cfg)
  int ready_pct = 100;   // chance per cycle that the register bus / SQE accepts a payload dword
  function new(string name = "cp_cfg");
    super.new(name);
  endfunction
endclass
