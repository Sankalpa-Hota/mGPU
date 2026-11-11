MOD      = 21_gmu
RTL      = ../../rtl/21_gmu/gmu.sv
TB_FILES = gmu_interface.sv gmu_pkg.sv gmu_assertions.sv gmu_tb_top.sv
TESTS    = gmu_smoke_test gmu_rand_test gmu_bursty_test gmu_blip_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_OFF_WHILE_BUSY TEST=gmu_rand_test
	@$(MAKE) -s bug BUG=BUG_AVAIL_EARLY    TEST=gmu_bursty_test
	@$(MAKE) -s bug BUG=BUG_IDLE_NO_RESET  TEST=gmu_blip_test
