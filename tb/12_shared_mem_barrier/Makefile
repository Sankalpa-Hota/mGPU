MOD      = 12_shared_mem_barrier
RTL      = ../../rtl/common/mgpu_pkg.sv ../../rtl/12_shared_mem_barrier/shared_mem.sv ../../rtl/12_shared_mem_barrier/barrier.sv
TB_FILES = smb_interface.sv smb_pkg.sv smb_assertions.sv smb_tb_top.sv
TESTS    = smb_smoke_test smb_rand_test smb_exit_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_NO_BROADCAST TEST=smb_rand_test
	@$(MAKE) -s bug BUG=BUG_NO_CONFLICT  TEST=smb_rand_test
	@$(MAKE) -s bug BUG=BUG_WRITE_ORDER  TEST=smb_rand_test
	@$(MAKE) -s bug BUG=BUG_COUNT_EXITED TEST=smb_exit_test
	@$(MAKE) -s bug BUG=BUG_NO_CLEAR     TEST=smb_rand_test
