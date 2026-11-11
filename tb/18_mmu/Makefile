MOD      = 18_mmu
RTL      = ../../rtl/18_mmu/mmu.sv
TB_FILES = mmu_interface.sv mmu_pkg.sv mmu_assertions.sv mmu_tb_top.sv
TESTS    = mmu_smoke_test mmu_rand_test mmu_remap_test mmu_tlb_thrash_test mmu_bypass_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_TLB_NO_INVAL TEST=mmu_remap_test
	@$(MAKE) -s bug BUG=BUG_PERM         TEST=mmu_rand_test
	@$(MAKE) -s bug BUG=BUG_PTE_INDEX    TEST=mmu_rand_test
