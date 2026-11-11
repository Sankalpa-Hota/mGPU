MOD      = 16_crossbar
RTL      = ../../rtl/16_crossbar/crossbar.sv
TB_FILES = xbar_interface.sv xbar_pkg.sv xbar_assertions.sv xbar_tb_top.sv
TESTS    = xbar_smoke_test xbar_rand_test xbar_hot_bank_test xbar_out_of_order_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_BANK_BIT  TEST=xbar_rand_test
	@$(MAKE) -s bug BUG=BUG_NO_HOLD   TEST=xbar_hot_bank_test
	@$(MAKE) -s bug BUG=BUG_RSP_ROUTE TEST=xbar_out_of_order_test
