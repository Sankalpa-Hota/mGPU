package ring_fetch_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "mgpu_coverage.sv"
  `include "ring_fetch_config.sv"
  `include "ring_fetch_transactions.sv"
  `include "ring_fetch_sequences.sv"
  `include "ring_fetch_cpu_driver.sv"
  `include "ring_fetch_memory_responder.sv"
  `include "ring_fetch_sink.sv"
  `include "ring_fetch_monitor.sv"
  `include "ring_fetch_scoreboard.sv"
  `include "ring_fetch_coverage.sv"
  `include "ring_fetch_env.sv"
  `include "ring_fetch_tests.sv"
endpackage
