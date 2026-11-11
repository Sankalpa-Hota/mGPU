MOD      = 04_rbbm
RTL      = ../../rtl/04_rbbm/rbbm.sv
TB_FILES = rbbm_interface.sv rbbm_pkg.sv rbbm_assertions.sv rbbm_tb_top.sv
TESTS    = rbbm_reset_value_test rbbm_bit_bash_test rbbm_static_reg_test rbbm_illegal_access_test \
           rbbm_irq_test rbbm_hang_test rbbm_perf_test rbbm_rand_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_W1C_LOSES_SET          TEST=rbbm_irq_test
	@$(MAKE) -s bug BUG=BUG_HANG_IGNORES_PROGRESS  TEST=rbbm_hang_test
	@$(MAKE) -s bug BUG=BUG_PERF_WRITE_LOST        TEST=rbbm_perf_test
