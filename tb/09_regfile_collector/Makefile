MOD      = 09_regfile_collector
RTL      = ../../rtl/common/mgpu_pkg.sv ../../rtl/09_regfile_collector/regfile_collector.sv
TB_FILES = rf_interface.sv rf_pkg.sv rf_assertions.sv rf_tb_top.sv
TESTS    = rf_smoke_test rf_rand_test rf_bank_stress_test rf_backpressure_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_WRITE_ALL_LANES TEST=rf_rand_test
	@$(MAKE) -s bug BUG=BUG_BANK_CONFLICT   TEST=rf_bank_stress_test
