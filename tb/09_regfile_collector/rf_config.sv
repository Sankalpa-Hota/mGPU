typedef virtual rf_interface rf_vif_t;
import mgpu_pkg::*;

class rf_config extends uvm_object;
  `uvm_object_utils(rf_config)
  int issue_pct = 70;      // chance per cycle that an instruction is offered
  int wb_pct    = 40;      // chance per cycle per port that a writeback is offered
  int ex_rdy_pct = 70;     // execution unit readiness
  int reg_span  = 16;
  int launch_pct = 1;
  function new(string name = "rf_config"); super.new(name); endfunction
endclass

// Shared hazard bookkeeping, the same rules the scoreboard enforces in the real sub-core:
//  - a register with a writeback in flight is not read by a newly issued instruction
//  - a register that the instruction in the collector reads is not written until it has been dispatched
class rf_hazards extends uvm_object;
  `uvm_object_utils(rf_hazards)
  int wb_inflight[4][16];
  bit [15:0] locked[4];
  bit busy_warp[4];
  function new(string name = "rf_hazards"); super.new(name); endfunction
endclass
