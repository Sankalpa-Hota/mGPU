MOD      = 07_warp_scheduler
RTL      = ../../rtl/common/mgpu_pkg.sv ../../rtl/07_warp_scheduler/warp_scheduler.sv
TB_FILES = ws_interface.sv ws_pkg.sv ws_assertions.sv ws_tb_top.sv
TESTS    = ws_smoke_test ws_rand_test ws_hazard_test ws_throughput_test ws_backpressure_test ws_control_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_NO_WAW   TEST=ws_hazard_test
	@$(MAKE) -s bug BUG=BUG_NO_HOLD  TEST=ws_backpressure_test
	@$(MAKE) -s bug BUG=BUG_RR_STUCK TEST=ws_backpressure_test
