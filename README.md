# mGPU

A small but complete GPU in SystemVerilog, built and verified block by block with UVM (Verilator 5 + UVM).

- Command processor (ring fetch, PM4 packet decoder, SQE), RBBM (APB registers, interrupts, hang watchdog, perf counters)
- Dispatcher, 2 SMs x 2 sub-cores x 4 warps x 8 threads: warp scheduler + scoreboard, SIMT divergence stack,
  banked register file + operand collector, ALU, SFU, LSU with coalescing, shared memory + barrier, I-cache, L1
- Crossbar, 2-bank write-back L2, MMU (2-level page tables, TLB, faults), GBIF (AXI4 master), DRAM controller
  (AXI4 slave with row-buffer timing), GMU (SM power gating)
- A full-chip testbench that drives the GPU like a driver: page tables, command ring, doorbell, interrupt,
  and compares all memory with an instruction-set simulator

## Layout

| Path | Contents |
|---|---|
| `rtl/<NN>_<block>/` | design of each block; `rtl/common/mgpu_pkg.sv` = ISA and sizes |
| `tb/<NN>_<block>/` | UVM testbench, `Makefile` (`make regress`, `make bugs`), `logs/` (per-test logs, text waveforms, merged coverage) |
| `tb/common/` | shared make rules, coverage bin counter, assembler, ISS, kernels |
| `uvm/` | the UVM library (Verilator port, Apache 2.0) |
| `scripts/` | log checker, coverage merge, `status.sh` (one line per block), `regress_all.sh` |
| `docs/modules/` | one PDF per block; `docs/mGPU_Design_and_Verification_Guide.pdf` = all of them |
| `docs/mGPU_RTL_Issue_Log.pdf` | every real RTL issue found during verification, why, fix, how it was caught, how to find such bugs |

Start with `docs/modules/00_mGPU_overview.pdf` (chip map, ISA, command stream, who talks to whom).

## Blocks

| Block | Regression | Merged coverage | Planted bugs caught |
|---|---|---|---|
| 01_cp_packet_decoder | 15/15 pass | 100.0% (28/28 bins) | 2/2 caught |
| 02_cp_ring_fetch | 18/18 pass | 100.0% (17/17 bins) | 2/2 caught |
| 03_cp_sqe | 18/18 pass | 100.0% (26/26 bins) | 3/3 caught |
| 04_rbbm | 24/24 pass | 100.0% (35/35 bins) | 3/3 caught |
| 05_dispatcher | 15/15 pass | 100.0% (20/20 bins) | 3/3 caught |
| 06_icache | 15/15 pass | 100.0% (14/14 bins) | 2/3 (BUG_FIXED_PRIO cannot fail in this system: see doc) |
| 07_warp_scheduler | 18/18 pass | 100.0% (15/15 bins) | 3/3 caught |
| 08_simt_stack | 15/15 pass | 100.0% (14/14 bins) | 3/3 caught |
| 09_regfile_collector | 12/12 pass | 100.0% (14/14 bins) | 2/2 caught |
| 10_alu | 9/9 pass | 100.0% (34/34 bins) | 3/3 caught |
| 11_sfu | 9/9 pass | 100.0% (14/14 bins) | 3/3 caught |
| 12_shared_mem_barrier | 9/9 pass | 100.0% (19/19 bins) | 5/5 caught |
| 13_lsu | 9/9 pass | 100.0% (15/15 bins) | 3/3 caught |
| 14_l1_dcache | 12/12 pass | 100.0% (13/13 bins) | 3/3 caught |
| 15_sm | 12/12 pass | 100.0% (19/19 bins) | 3/3 caught |
| 16_crossbar | 12/12 pass | 100.0% (14/14 bins) | 3/3 caught |
| 17_l2_cache | 15/15 pass | 100.0% (15/15 bins) | 4/4 caught |
| 18_mmu | 15/15 pass | 100.0% (14/14 bins) | 3/3 caught |
| 19_gbif | 12/12 pass | 100.0% (11/11 bins) | 3/3 caught |
| 20_dram_ctrl | 12/12 pass | 100.0% (15/15 bins) | 4/4 caught |
| 21_gmu | 12/12 pass | 100.0% (12/12 bins) | 3/3 caught |
| 22_mgpu_top | 14/14 pass | 100.0% (16/16 bins) | system level: block bugs verified in their benches |

`scripts/status.sh` regenerates this table from the logs.
