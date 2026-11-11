MOD      = 02_cp_ring_fetch
RTL      = ../../rtl/02_cp_ring_fetch/cp_ring_fetch.sv
TB_FILES = ring_fetch_interface.sv ring_fetch_pkg.sv ring_fetch_assertions.sv ring_fetch_tb_top.sv
TESTS    = ring_fetch_smoke_test ring_fetch_rand_test ring_fetch_slow_sink_test ring_fetch_slow_mem_test \
           ring_fetch_full_ring_test ring_fetch_wrap_stress_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_LINE_CROSS TEST=ring_fetch_rand_test
	@$(MAKE) -s bug BUG=BUG_FIFO_ROOM  TEST=ring_fetch_slow_sink_test
