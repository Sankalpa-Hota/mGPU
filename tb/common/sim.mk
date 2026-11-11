# Shared build/run rules. Each module Makefile sets MOD, RTL, TB_FILES, TESTS and includes this file.
ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
UVM_HOME ?= $(ROOT)/uvm
TEST     ?= $(firstword $(TESTS))
SEED     ?= 1
TIMEOUT  ?= 50000000
DEFS     ?=
LOGDIR   := logs
OBJ      := obj_dir$(if $(BUG),_$(BUG))

VFLAGS = --binary -j 8 --timing --assert --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style \
         +define+UVM_NO_DPI $(DEFS) +incdir+$(UVM_HOME) +incdir+. +incdir+$(ROOT)/tb/common +incdir+$(ROOT)/rtl/$(MOD) \
         --Mdir $(OBJ) --top-module tb_top -o vtb

.PHONY: build run regress bug clean

$(OBJ)/vtb: $(RTL) $(TB_FILES) $(wildcard *.sv) $(wildcard $(ROOT)/tb/common/*.sv)
	@echo "building $(MOD) $(DEFS)"; verilator $(VFLAGS) $(UVM_HOME)/uvm_pkg.sv $(RTL) $(TB_FILES) > build.log 2>&1 || (tail -40 build.log; exit 1)

build: $(OBJ)/vtb

run: build
	@mkdir -p $(LOGDIR)
	./$(OBJ)/vtb +UVM_TESTNAME=$(TEST) +verilator+seed+$(SEED) +UVM_TIMEOUT=$(TIMEOUT),NO +WAVE=$(LOGDIR)/$(TEST)_s$(SEED)_wave.txt \
	  > $(LOGDIR)/$(TEST)_s$(SEED).log 2>&1 ; \
	$(ROOT)/scripts/check_log.sh $(LOGDIR)/$(TEST)_s$(SEED).log

regress: build
	@mkdir -p $(LOGDIR); rm -f $(LOGDIR)/regress.txt
	@for t in $(TESTS); do for s in $(SEEDS); do \
	  $(MAKE) -s run TEST=$$t SEED=$$s | tee -a $(LOGDIR)/regress.txt; done; done
	@python3 $(ROOT)/scripts/merge_coverage.py $(LOGDIR) | tee -a $(LOGDIR)/regress.txt

# Bug-injection run: rebuild with a define that plants a known RTL bug; the test must FAIL.
bug:
	@mkdir -p $(LOGDIR)
	$(MAKE) -s build DEFS=+define+$(BUG) BUG=$(BUG)
	./obj_dir_$(BUG)/vtb +UVM_TESTNAME=$(TEST) +verilator+seed+1 +UVM_TIMEOUT=$(TIMEOUT),NO +WAVE=$(LOGDIR)/bug_$(BUG)_wave.txt \
	  > $(LOGDIR)/bug_$(BUG).log 2>&1 ; \
	$(ROOT)/scripts/check_log.sh $(LOGDIR)/bug_$(BUG).log expect_fail

clean:
	rm -rf obj_dir* build.log
