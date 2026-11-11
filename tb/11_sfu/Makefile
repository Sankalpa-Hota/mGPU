MOD      = 11_sfu
RTL      = ../../rtl/common/mgpu_pkg.sv ../../rtl/11_sfu/sfu.sv
TB_FILES = sfu_interface.sv sfu_pkg.sv sfu_assertions.sv sfu_tb_top.sv
TESTS    = sfu_smoke_test sfu_rand_test sfu_backpressure_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_DIV0        TEST=sfu_rand_test
	@$(MAKE) -s bug BUG=BUG_ISQRT_ITER  TEST=sfu_rand_test
	@$(MAKE) -s bug BUG=BUG_BUSY_ACCEPT TEST=sfu_backpressure_test
