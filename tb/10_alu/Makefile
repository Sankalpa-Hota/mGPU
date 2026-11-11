MOD      = 10_alu
RTL      = ../../rtl/common/mgpu_pkg.sv ../../rtl/10_alu/alu.sv
TB_FILES = alu_interface.sv alu_pkg.sv alu_assertions.sv alu_tb_top.sv
TESTS    = alu_smoke_test alu_rand_test alu_backpressure_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_SLT_UNSIGNED TEST=alu_rand_test
	@$(MAKE) -s bug BUG=BUG_SHIFT_AMOUNT TEST=alu_rand_test
	@$(MAKE) -s bug BUG=BUG_TID          TEST=alu_rand_test
