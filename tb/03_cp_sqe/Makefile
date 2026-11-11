MOD      = 03_cp_sqe
RTL      = ../../rtl/03_cp_sqe/cp_sqe.sv
TB_FILES = sqe_interface.sv sqe_pkg.sv sqe_assertions.sv sqe_tb_top.sv
TESTS    = sqe_smoke_test sqe_rand_test sqe_wfi_race_test sqe_event_test sqe_unknown_op_test sqe_busy_storm_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_WFI_NO_SETTLE  TEST=sqe_wfi_race_test
	@$(MAKE) -s bug BUG=BUG_IRQ_BEFORE_ACK TEST=sqe_event_test
	@$(MAKE) -s bug BUG=BUG_STRB           TEST=sqe_event_test
