// One kernel launch as the driver software performs it: program 3 registers, then DISPATCH.
class disp_kernel extends uvm_sequence_item;
  `uvm_object_utils(disp_kernel)
  rand bit [31:0] pc, arg, nwarps_raw, num_wg;
  rand bit        rewrite_cfg;   // program the next kernel's registers while this one still launches
  rand int        gap;
  int max_wg = 12;
  constraint c_pc  { pc[1:0] == 0; }
  constraint c_nw  { nwarps_raw inside {[0:6]}; }
  constraint c_wg  { num_wg inside {[0:max_wg]}; }
  constraint c_gap { gap inside {[0:5]}; }
  function new(string name = "disp_kernel");
    super.new(name);
  endfunction
  function string convert2string();
    return $sformatf("kernel pc=%08h arg=%08h warps=%0d wgs=%0d", pc, arg, nwarps_raw, num_wg);
  endfunction
endclass
