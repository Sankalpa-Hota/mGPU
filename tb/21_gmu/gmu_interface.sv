interface gmu_interface (input logic clk, input logic rst_n);
  logic [15:0] idle_limit;
  logic [1:0]  sm_busy, sm_want, sm_avail, sm_power, stat_off_pulse, stat_wake_pulse;
endinterface
