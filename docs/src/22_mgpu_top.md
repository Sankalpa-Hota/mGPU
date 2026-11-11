# 22 mGPU top: the complete GPU

## What this block is, in plain words

All 21 blocks connected into one GPU, plus a DRAM. A CPU (the testbench) talks to it only the way real software does: register writes over APB, commands in a ring buffer in memory, and an interrupt when the work is done.

```hflow
CPU -APB-> RBBM -WPTR-> CP fetch -> decoder -> SQE -> dispatcher -> SM x2
SM x2 -> crossbar -> L2 bank x2 -> arbiter -> MMU -> GBIF -AXI4-> DRAM
CP fetch -uncached-> arbiter
SQE fences -uncached-> arbiter
```

## System-level design decisions and why

| Decision | Why |
|---|---|
| The command ring and the fences take an **uncached path** (they join below the L2) | The CPU writes the ring and reads the fences directly in DRAM. A cached ring line fetched while only half written would return stale commands later; a fence held dirty in the L2 would never reach the CPU. |
| L2 flush = clean + invalidate (issue log R9) | Between kernels the CPU writes code and data directly to DRAM. |
| Register writes in the command stream wait for the SQE | A register write after WAIT_FOR_IDLE must not overtake it. |
| SM caches invalidated on every DISPATCH | New kernel, possibly new code and data. |
| Control registers 0x200-0x205 (PTBR, MMU enable, TLB invalidate, L2 flush, GMU idle limit, fault clear) written by type 4 packets | Configuration stays in order with the work it applies to. |
| Busy bits: 0 dispatcher + SMs, 1 L2 (including flush), 2 memory path below the L2 (L2 traffic only), 3 command fetch | Bit 2 must not count the command fetch: WAIT_FOR_IDLE is itself a command, so it would wait for itself. |
| Soft reset (RBBM) resets everything except the RBBM | The CPU keeps its register access while the GPU restarts. |

## Driver sequence used by the testbench (what a real driver does)

1. Read ID; build page tables in DRAM; program ring base, interrupt mask, watchdog, performance counter selects.
2. Ring: PTBR + MMU on, TLB invalidate, GMU idle limit; write WPTR.
3. Per kernel: write code, arguments and data into DRAM; ring: kernel registers, DISPATCH, WAIT_FOR_IDLE (0x7), L2 flush, WAIT_FOR_IDLE (0x6), EVENT_WRITE (fence, value); write WPTR.
4. Wait for the interrupt; read IRQ_STATUS and write it back (W1C); check the fence value in DRAM; compare all memory with the ISS through the page tables.

## Tests

| Test | What it proves |
|---|---|
| `top_smoke_test` | vector add end to end |
| `top_kernels_test` | all 7 kernels back to back, 6 workgroups each |
| `top_random_test` | 6 random kernels, 1-8 workgroups of 1-4 warps |
| `top_scrambled_mmu_test` | the same kernels with data pages scattered over physical memory |
| `top_power_test` | SMs power off between kernels and wake for the next |
| `top_mmu_fault_test` | the output page is unmapped: the MMU reports the right fault address and the GPU still finishes and interrupts |
| `top_ring_wrap_test` | 70 kernels: the 1024-dword command ring wraps |

**System assertions.** No SM busy while powered off; no SIMT overflow; the CP never sees an illegal packet or opcode (driver and GPU agree on the format).

## Results

| Test (seed 1) | Kernels | GPU cycles | Perf counters (SM0 issue / TLB hits / DRAM row hits / SM power-offs) |
|---|---|---|---|
| `top_smoke_test` | 1 | 1,220 | 65 / 24 / 22 / 0 |
| `top_kernels_test` | 7 | 11,142 | 1,754 / 316 / 238 / 0 |
| `top_random_test` | 6 | 172,952 | 4,717 / 6,866 / 3,102 / 0 |
| `top_scrambled_mmu_test` | 7 | 11,142 | 1,754 / 316 / 238 / 0 |
| `top_power_test` | 7 | 11,142 | 1,754 / 316 / 238 / **15** |
| `top_mmu_fault_test` | 1 | 1,374 | fault reported at the unmapped OUT page; GPU completed and interrupted |
| `top_ring_wrap_test` | 70 | 33,671 | ring wrapped; every fence and result correct |

| Item | Result |
|---|---|
| Regression | 7 tests x 2 seeds = 14 runs, all PASS; every result identical to the ISS, every fence correct, no hang interrupt |
| Merged coverage | 100% (16 of 16) |
| Planted bugs | every block bug is verified in its own bench; the integration bugs of the SM (block 15) are reachable here too |
| Real issues found at this level | R9 (L2 flush semantics) and R10 (uncached command and fence path), both by design review while integrating |

**A performance observation.** The kernels, scrambled-MMU and power tests report the same kernel times to the cycle. For the scrambled MMU this is expected: translation happens below the L2 and the TLB stays warm. For power gating it is less obvious, so it was measured in the waveforms: the SMs really are off between kernels (both SMs powered down for 740 of the first 3,000 cycles), and waking them delays the first workgroup launch by 7 cycles (DISPATCH in cycle 139, first launch in cycle 147 instead of 140). The end-to-end kernel time is nevertheless unchanged, so that start-up delay is absorbed by a later bottleneck, most likely the single memory path below the L2 that the first instruction and data fetches of every workgroup queue on. Proving which resource absorbs it is a good performance-analysis exercise with the per-cycle logs.

# Teaching section: the mGPU top in context

## The block and its pins

```pins
block: mgpu_top | mgpu_top.sv (GPU) + mgpu_system.sv (GPU + DRAM) · 2 SMs · 2 L2 banks · one AXI4 port
in: psel, penable, pwrite, paddr[11:0], pwdata | CPU (APB) | register access into the RBBM
in: dram_perf[15:0] | DRAM controller | [0] row hit, [1] row miss pulses for the perf counters
out: prdata, pready, pslverr | CPU (APB) | register read data and completion
out: irq | CPU | fence / error interrupt from the RBBM
out: mmu_fault, mmu_fault_va | CPU / system | sticky first MMU fault and its virtual address
out: araddr, arlen, arsize, arburst, arvalid / arready | DRAM controller (AR) | read bursts from the GBIF
in: rdata, rresp, rlast, rvalid / rready | DRAM controller (R) | read beats
out: awaddr, awlen, awsize, awburst, awvalid / awready | DRAM controller (AW) | write bursts from the GBIF
out: wdata, wstrb, wlast, wvalid / wready | DRAM controller (W) | write beats
in: bresp, bvalid / bready | DRAM controller (B) | write responses
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

`mgpu_system` has only the APB, `irq` and `mmu_fault` pins: it wires all the AXI pins of `mgpu_top` to a `dram_ctrl` (MW = 20, that is 1 MB, T_HIT = 2, T_MISS = 8) and feeds `dram_perf = {14'd0, row_miss, row_hit}`.

## Where it sits: the full chip

```hflow
CPU | APB writes -APB-> RBBM | registers, irq -ring ptrs-> CP | fetch, decode, SQE -DISPATCH-> Dispatcher + GMU | launch, power -workgroups-> SMs x2 | execute -lines-> Crossbar + L2 x2 | cache -misses-> Arbiter + MMU | translate -lines-> GBIF | AXI4 master | you -AXI4-> DRAM | dram_ctrl
```

The command ring and the fences take an **uncached path**: the CP ring fetch and the SQE fence writes enter the line arbiter directly, beside the two L2 banks, so they always see DRAM as the CPU wrote it. Four requesters share the single MMU: L2 bank 0, L2 bank 1, ring fetch, SQE.

Control registers, written by type-4 packets from the ring (so they take effect in order with the other commands):

| Address | Name | Effect |
|---|---|---|
| 0x100-0x102 | dispatcher | kernel PC, warps per workgroup, argument base (decoded by the dispatcher itself) |
| 0x200 | PTBR | physical base of the level-1 page table |
| 0x201 | MMU_ENABLE | bit 0 turns translation on |
| 0x202 | TLB_INVALIDATE | any write: one-cycle pulse that clears the TLB |
| 0x203 | L2_FLUSH | any write: both banks clean (write back dirty lines) and invalidate; pending until each bank reports done |
| 0x204 | GMU_IDLE_LIMIT | bits 15-0: idle cycles before an SM is power gated, 0 = never |
| 0x205 | MMU_FAULT_CLEAR | any write: one-cycle pulse that re-arms the fault record |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| CPU / driver model (testbench) | APB, irq | Sets the ring base and write pointer, reads status and perf counters, takes interrupts, issues soft reset. |
| CPU / system | mmu_fault, mmu_fault_va | Notices translation faults without polling a register. |
| DRAM controller (20) | AXI4 ports, dram_perf | Holds program, data, page tables, ring and fences; reports row hits/misses. |
| Inside: RBBM | busy_bits, progress, perf_ev | Busy bits 0 dispatcher+SMs, 1 L2 (including flush), 2 L2 traffic below the L2, 3 command fetch; used by WAIT_FOR_IDLE and the hang detector. |

## Design details

- **Two resets.** `rst_n` resets everything; the RBBM's `soft_reset` resets everything except the RBBM itself (`core_rst_n = rst_n && !soft_reset`), so the CPU keeps its register access while the rest of the GPU restarts.
- **Registers in the command stream.** Control registers are not APB registers; they are written by packets in the ring. The decoder waits for the SQE before each register write, so "set PTBR, invalidate TLB, then dispatch" happens in exactly that order.
- **Pulse registers.** TLB_INVALIDATE and MMU_FAULT_CLEAR are self-clearing one-cycle pulses: any write fires them. L2_FLUSH sets one pending bit per bank, and each bit clears when its bank raises `flush_done`; while pending it counts as busy.
- **Kernel start invalidates.** `kernel_start = disp_valid && disp_ready` invalidates every SM's instruction cache and L1, so a new kernel never sees stale code or data from the last one.
- **Slot numbering.** The dispatcher has 4 slots; slot s is SM (s mod 2), sub-core (s / 2). So consecutive workgroups go to different SMs first.
- **One path to memory.** Everything below the L2 is serialised: arbiter, then a blocking MMU, then a single-outstanding GBIF. That keeps the design easy to verify and is the main performance bottleneck (see the observation above).
- **Busy bit 2 excludes the CP's own traffic.** Only L2 requests count as "below the L2 busy". If the ring fetch counted, WAIT_FOR_IDLE (itself fetched from the ring) would wait for itself forever.

## Questions: what if we did it differently?

**Q1. What if control registers were written over APB directly instead of through the ring?**
APB writes happen immediately, out of order with the commands already queued. A CPU writing PTBR while an earlier kernel is still running would change its translations mid-flight. Real GPUs do both: a few "privileged" registers on the bus, and most state through the command stream so it is ordered. The bench would need explicit waits for idle before each APB write.

**Q2. What if the ring and fences went through the L2 (cached)?**
Then the CPU's ring writes in DRAM might be hidden by a stale L2 copy, and the CPU would read old fence values. To make that work you need coherence: either snooping the CPU's writes, explicit flush/invalidate commands around every ring update, or marking those pages uncacheable in the page table (a memory-type attribute). The uncached side path is the simplest correct answer.

**Q3. One shared memory path versus several channels?**
Real GPUs have many memory channels, each with its own controller, and the L2 slices are mapped to channels by address. Here: give each L2 bank its own MMU+GBIF and its own AXI port. Bandwidth doubles; you need per-channel address interleaving and a TLB per channel (or a shared TLB with more ports). The system model would instantiate two DRAM controllers and the scoreboard would merge their memories.

**Q4. Why a crossbar between SMs and L2 banks instead of a shared bus or a NoC?**
A shared bus lets only one SM talk at a time; a crossbar lets SM0 use bank 0 while SM1 uses bank 1. With many SMs a full crossbar grows as N times M, so large GPUs use hierarchical crossbars or a network-on-chip (rings, meshes). For 2 by 2, the crossbar is the obvious choice.

**Q5. APB versus AXI-Lite for the CPU port?**
APB is the simplest register bus: one transfer at a time, no bursts, which fits a handful of control registers. AXI-Lite would allow separate read/write channels and outstanding accesses, useful if the CPU polls heavily while also writing. For a register block APB is enough.

**Q6. What if TLB_INVALIDATE were not ordered with the L2 flush?**
With a virtually-addressed L2 above the MMU, changing a mapping requires: flush the L2 (so dirty lines are written back with the old translation), then invalidate the TLB, then dispatch. If the invalidate happened first, the flush's writebacks would be translated with a new or missing mapping and land in the wrong place or fault. The ring order is the protection; a test should remap a page with dirty L2 lines and check where the data lands.

**Q7. What if the GPU interrupted on every MMU fault instead of exposing a sticky pin?**
An interrupt per fault can flood the CPU. Recording the first fault and requiring an explicit clear (0x205) is the common pattern. A richer design adds a fault FIFO with several entries and an interrupt on "FIFO not empty", which is how replayable-fault GPUs report many faults.

**Q8. What would a power-aware top add?**
Today the GMU's `sm_power` is only observed. A real chip would wire it to power switches, add isolation cells on the SM's outputs while it is off (so floating signals do not corrupt the crossbar), and add a power-intent file (UPF) describing the power domains. Verification would add power-aware simulation in which an OFF SM's outputs go to X unless isolated.

**Q9. How do the block bugs show up at this level?**
Each block's planted bugs are verified in its own bench, but at the top they become system symptoms: an MMU `BUG_TLB_NO_INVAL` shows as a kernel reading old data after a remap; a GBIF `BUG_W_AFTER_AW` or `BUG_WLAST` shows as a hang that the RBBM hang detector reports (no progress); a DRAM `BUG_WSTRB_IGNORE` shows as a fence write corrupting neighbouring words; a GMU `BUG_AVAIL_EARLY` shows as a launch during WAKING. Debugging from the top means tracing a wrong result back down this chain.
