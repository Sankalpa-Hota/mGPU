MOD      = 22_mgpu_top
R        = ../../rtl
RTL      = $(R)/common/mgpu_pkg.sv $(R)/04_rbbm/rbbm.sv $(R)/02_cp_ring_fetch/cp_ring_fetch.sv \
           $(R)/01_cp_packet_decoder/cp_packet_decoder.sv $(R)/03_cp_sqe/cp_sqe.sv $(R)/05_dispatcher/dispatcher.sv \
           $(R)/06_icache/icache.sv $(R)/07_warp_scheduler/warp_scheduler.sv $(R)/08_simt_stack/simt_stack.sv \
           $(R)/09_regfile_collector/regfile_collector.sv $(R)/10_alu/alu.sv $(R)/11_sfu/sfu.sv \
           $(R)/12_shared_mem_barrier/shared_mem.sv $(R)/12_shared_mem_barrier/barrier.sv $(R)/13_lsu/lsu.sv \
           $(R)/14_l1_dcache/l1_dcache.sv $(R)/15_sm/line_arbiter.sv $(R)/15_sm/subcore.sv $(R)/15_sm/sm.sv \
           $(R)/16_crossbar/crossbar.sv $(R)/17_l2_cache/l2_cache.sv $(R)/18_mmu/mmu.sv $(R)/19_gbif/gbif.sv \
           $(R)/20_dram_ctrl/dram_ctrl.sv $(R)/21_gmu/gmu.sv $(R)/22_mgpu_top/mgpu_top.sv $(R)/22_mgpu_top/mgpu_system.sv
TB_FILES = top_interface.sv top_pkg.sv top_assertions.sv top_tb_top.sv
TESTS    = top_smoke_test top_kernels_test top_random_test top_scrambled_mmu_test top_power_test top_mmu_fault_test top_ring_wrap_test
SEEDS    = 1 2
TIMEOUT  = 400000000

include ../common/sim.mk

bugs:
	@echo "full-chip bugs: see the block benches (every planted bug is also reachable here)"
