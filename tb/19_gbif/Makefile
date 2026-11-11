MOD      = 19_gbif
RTL      = ../../rtl/19_gbif/gbif.sv
TB_FILES = gbif_interface.sv gbif_pkg.sv axi_protocol_checker.sv gbif_tb_top.sv
TESTS    = gbif_smoke_test gbif_rand_test gbif_error_test gbif_w_first_slave_test
SEEDS    = 1 2 3

include ../common/sim.mk

bugs:
	@$(MAKE) -s bug BUG=BUG_W_AFTER_AW  TEST=gbif_w_first_slave_test
	@$(MAKE) -s bug BUG=BUG_WLAST       TEST=gbif_rand_test
	@$(MAKE) -s bug BUG=BUG_RBEAT_ORDER TEST=gbif_rand_test
