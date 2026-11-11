MOD      = 14_l1_dcache
RTL      = ../../rtl/14_l1_dcache/l1_dcache.sv
TB_FILES = l1_interface.sv l1_pkg.sv l1_assertions.sv l1_tb_top.sv
TESTS    = l1_smoke_test l1_rand_test l1_conflict_test l1_invalidate_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_WRITE_NO_UPDATE TEST=l1_rand_test
	@$(MAKE) -s bug BUG=BUG_LRU             TEST=l1_conflict_test
	@$(MAKE) -s bug BUG=BUG_STRB_MERGE      TEST=l1_rand_test
