MOD      = 13_lsu
RTL      = ../../rtl/common/mgpu_pkg.sv ../../rtl/13_lsu/lsu.sv
TB_FILES = lsu_interface.sv lsu_pkg.sv lsu_assertions.sv lsu_tb_top.sv
TESTS    = lsu_smoke_test lsu_rand_test lsu_slow_memory_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_COALESCE_OFF TEST=lsu_rand_test
	@$(MAKE) -s bug BUG=BUG_STRB_LANE    TEST=lsu_rand_test
	@$(MAKE) -s bug BUG=BUG_LOAD_WORD    TEST=lsu_rand_test
