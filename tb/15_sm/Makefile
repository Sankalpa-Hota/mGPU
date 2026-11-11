MOD      = 15_sm
R        = ../../rtl
RTL      = $(R)/common/mgpu_pkg.sv $(R)/06_icache/icache.sv $(R)/07_warp_scheduler/warp_scheduler.sv \
           $(R)/08_simt_stack/simt_stack.sv $(R)/09_regfile_collector/regfile_collector.sv $(R)/10_alu/alu.sv \
           $(R)/11_sfu/sfu.sv $(R)/12_shared_mem_barrier/shared_mem.sv $(R)/12_shared_mem_barrier/barrier.sv \
           $(R)/13_lsu/lsu.sv $(R)/14_l1_dcache/l1_dcache.sv $(R)/15_sm/line_arbiter.sv $(R)/15_sm/subcore.sv $(R)/15_sm/sm.sv
TB_FILES = sm_interface.sv sm_pkg.sv sm_assertions.sv sm_tb_top.sv
TESTS    = sm_vector_add_test sm_kernels_test sm_random_kernel_test sm_slow_memory_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_MASK_NOT_PASSED   TEST=sm_kernels_test
	@$(MAKE) -s bug BUG=BUG_WG_DONE_EARLY     TEST=sm_slow_memory_test
	@$(MAKE) -s bug BUG=BUG_L1_NO_INVALIDATE  TEST=sm_kernels_test
