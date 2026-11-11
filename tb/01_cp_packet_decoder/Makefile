MOD      = 01_cp_packet_decoder
RTL      = ../../rtl/01_cp_packet_decoder/cp_packet_decoder.sv
TB_FILES = cp_decoder_interface.sv cp_decoder_pkg.sv cp_decoder_assertions.sv cp_decoder_tb_top.sv
TESTS    = cp_directed_test cp_rand_test cp_backpressure_test cp_bad_pkt_test cp_corner_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_T4_NOINC   TEST=cp_rand_test
	@$(MAKE) -s bug BUG=BUG_ZERO_COUNT TEST=cp_directed_test
