MOD      = 08_simt_stack
RTL      = ../../rtl/common/mgpu_pkg.sv ../../rtl/08_simt_stack/simt_stack.sv
TB_FILES = simt_interface.sv simt_pkg.sv simt_assertions.sv simt_tb_top.sv
TESTS    = simt_smoke_test simt_rand_test simt_uniform_test simt_deep_test simt_overflow_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_NO_POP     TEST=simt_rand_test
	@$(MAKE) -s bug BUG=BUG_PUSH_ORDER TEST=simt_rand_test
	@$(MAKE) -s bug BUG=BUG_EXIT_MASK  TEST=simt_deep_test
