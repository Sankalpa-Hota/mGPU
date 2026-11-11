MOD      = 06_icache
RTL      = ../../rtl/06_icache/icache.sv
TB_FILES = icache_interface.sv icache_pkg.sv icache_assertions.sv icache_tb_top.sv
TESTS    = icache_smoke_test icache_rand_test icache_stream_test icache_contention_test icache_invalidate_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_NO_VALID   TEST=icache_invalidate_test
	@$(MAKE) -s bug BUG=BUG_FIXED_PRIO TEST=icache_contention_test
	@$(MAKE) -s bug BUG=BUG_TAG_BITS   TEST=icache_rand_test
