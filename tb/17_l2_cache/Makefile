MOD      = 17_l2_cache
RTL      = ../../rtl/17_l2_cache/l2_cache.sv
TB_FILES = l2_interface.sv l2_pkg.sv l2_assertions.sv l2_tb_top.sv
TESTS    = l2_smoke_test l2_rand_test l2_eviction_test l2_fault_test l2_cpu_writes_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_NO_WRITEBACK    TEST=l2_eviction_test
	@$(MAKE) -s bug BUG=BUG_DIRTY_NOT_SET   TEST=l2_rand_test
	@$(MAKE) -s bug BUG=BUG_PARTIAL_NO_FILL TEST=l2_rand_test
	@$(MAKE) -s bug BUG=BUG_FLUSH_KEEPS_LINES TEST=l2_cpu_writes_test
