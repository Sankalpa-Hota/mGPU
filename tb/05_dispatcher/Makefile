MOD      = 05_dispatcher
RTL      = ../../rtl/05_dispatcher/dispatcher.sv
TB_FILES = dispatcher_interface.sv dispatcher_pkg.sv dispatcher_assertions.sv dispatcher_tb_top.sv
TESTS    = dispatcher_smoke_test dispatcher_rand_test dispatcher_full_test dispatcher_power_test dispatcher_short_wg_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_LIVE_CONFIG  TEST=dispatcher_rand_test
	@$(MAKE) -s bug BUG=BUG_IGNORE_AVAIL TEST=dispatcher_power_test
	@$(MAKE) -s bug BUG=BUG_BUSY_EARLY   TEST=dispatcher_full_test
