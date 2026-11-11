MOD      = 20_dram_ctrl
RTL      = ../../rtl/20_dram_ctrl/dram_ctrl.sv
TB_FILES = dram_interface.sv dram_pkg.sv axi_protocol_checker.sv dram_tb_top.sv
TESTS    = dram_smoke_test dram_rand_test dram_row_test dram_error_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_WSTRB_IGNORE TEST=dram_rand_test
	@$(MAKE) -s bug BUG=BUG_RLAST_EARLY  TEST=dram_rand_test
	@$(MAKE) -s bug BUG=BUG_NO_DECERR    TEST=dram_error_test
	@$(MAKE) -s bug BUG=BUG_RDATA_LIVE   TEST=dram_rand_test
