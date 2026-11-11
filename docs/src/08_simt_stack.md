# 08 SIMT stack (divergence and reconvergence)

## What this block is, in plain words

All 8 threads of a warp share one program counter. When a branch sends some threads one way and some the other (**divergence**), the warp runs the two paths one after the other, each time with only the threads that belong to it switched on (the **active mask**). When both paths reach the point where they meet again (the **reconvergence point**, or join) the warp continues with all threads together. The SIMT stack remembers which paths are still to run and where they rejoin.

## Where it sits and who talks to it

| Who | Talks to | For what | Signals |
|---|---|---|---|
| Launch | SIMT stack | start warps at a pc with all 8 lanes | `wl_mask`, `wl_pc` |
| Scheduler, barrier | SIMT stack | a non-control instruction issued (or a barrier released): pc + 4 | `adv_mask` |
| ALU | SIMT stack | a branch / JMP / EXIT with the lanes for which the condition holds | `br_valid`, `br_warp`, `br_instr`, `br_pc`, `br_taken` |
| SIMT stack | scheduler, collector, sub-core | each warp's pc, mask, liveness; branch done; warp finished | `pc`, `mask`, `live`, `ctrl_done`, `warp_exit`, `overflow` |

## How the stack works (post-dominator stack)

Each entry is `{pc, mask, rpc}`; the top entry is what runs now. Branch instructions carry the join as an offset.

| Event | Action |
|---|---|
| advance | top.pc += 4; then **pop** every top entry whose pc reached its rpc |
| branch, all active lanes agree | just jump or fall through |
| branch, lanes split | top becomes the reconvergence entry (pc = join); push not-taken {pc+4}; push taken {target}; both with rpc = join; taken runs first |
| EXIT | the active lanes leave every entry; empty entries are popped; empty stack = warp finished |

Two refinements (issue log R6): an entry whose pc already equals the join is not pushed; and if the top entry already reconverges at the same join (a divergent loop branch inside its own loop), it is **replaced** instead of nested, so loops use constant stack depth.

## RTL decisions and why

| Decision | Why |
|---|---|
| Depth 7 per warp | 1 base + 2 per nesting level: 3 levels of nested divergence. Deeper code sets the sticky `overflow` flag and degrades (treats the branch as uniform) rather than corrupting memory. |
| Reconvergence pop loops (several pops in one cycle) | Nested regions can end at the same pc. |
| EXIT clears lanes in every entry | Otherwise exited lanes come back to life at the next reconvergence (`BUG_EXIT_MASK`). |
| Taken path first | A fixed order makes behaviour deterministic and checkable (`BUG_PUSH_ORDER` swaps it). |

## Trace (from the simulation)

Smoke test, warp 1 (taken from `logs/simt_smoke_test_s1_wave.txt`):

| Cycle | Event | pc after | mask after | stack depth |
|---|---|---|---|---|
| 4 | branch at pc 0x0C, lanes split: taken = `00110110` | 0x10 (target) | `00110110` | 3 (base, not-taken, taken) |
| 65 | the taken path is done; the not-taken lanes `11001001` run, then reach the join | 0x34 | `11111111` | 1 |
| 72 | warp 0 executes EXIT with all lanes | - | - | warp 0 no longer live |

The taken lanes ran first, the others followed, and at the join (0x34) all 8 lanes run together again.

## Verification decisions and why

**What we check, two independent ways.**

1. **Semantics.** Every lane, run alone through the program with the same branch decisions, gives a list of pcs. The list of pcs each lane executed in the DUT (every step whose mask contains it) must be identical. This is the true meaning of SIMT and does not depend on how the stack is built.
2. **Reconvergence.** A golden PDOM stack fed with the same steps must show the same pc and mask as the DUT before every step. A missing pop or a wrong push order keeps per-lane semantics but wastes cycles; only this check catches it.

| Decision | Why |
|---|---|
| Random **structured** programs (if/else, if-only, loops, early exits) with the real branch encoding | Unstructured random jumps have no meaningful join points; real compilers produce structured code. |
| Branch decisions depend on lane, pc and the visit count | Lanes really diverge, loops really run different numbers of times per lane, and the scalar reference reproduces exactly the same decisions. |
| Loops stop after 4 iterations | Every program terminates. |
| Overflow test with nesting depth 5 | The overflow flag must be set exactly when the golden stack overflows. |

**Coverage (14 bins).** Uniform taken, uniform not taken, divergent; depth 3, 5, 7; loop divergence; partial and whole-warp exit; JMP; target equal to join; top-entry reuse; 4 warps live; overflow. A "two pops in one cycle" bin was removed after the reuse refinement made it unreachable.

**Assertions.** Live warps have lanes, `ctrl_done` only after a branch, `warp_exit` only for dead warps, overflow sticky.

## Results

| Item | Result |
|---|---|
| Regression | 5 tests x 3 seeds = 15 runs, all PASS (up to 45,000 steps and 3,840 lane traces per run) |
| Merged coverage | 100% (14 of 14) |
| `BUG_NO_POP` | caught by the golden stack: `DUT pc=0000009c mask=00000010, golden pc=00000004 mask=11001001` |
| `BUG_PUSH_ORDER` | caught by the golden stack (per-lane traces alone stay correct) |
| `BUG_EXIT_MASK` | caught: exited lanes come back (`DUT mask=11011110, golden mask=01010110`) |
| Real RTL issue found | divergent loops grew the stack (R6) |

# Teaching section: the SIMT stack in context

## The block and its pins

```pins
block: SIMT stack | simt_stack.sv · 4 warps · 7 entries per warp · owns every pc and mask
in: wl_mask, wl_pc | subcore launch logic | start these warps at this PC with all 8 lanes active
in: adv_mask | warp scheduler and barrier | step this warp's PC by 4 (ordinary instruction issued, or barrier released)
in: br_valid, br_warp, br_instr, br_pc | ALU | a branch / JMP / EXIT has been evaluated for this warp
in: br_taken[8] | ALU | per-lane outcome of BEQ/BNE
out: pc[4], live | warp scheduler | each warp's current PC; which warps still have lanes
out: mask[4] | operand collector (via subcore) | each warp's active lanes, attached to every issued instruction
out: ctrl_done | warp scheduler | the control instruction is resolved: the warp may fetch again
out: warp_exit | subcore | the warp's last lanes have exited
out: overflow, depth[4] | statistics | a push did not fit (sticky); current stack depth per warp
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the sub-core pipeline

```hflow
ALU | evaluates branch -br_taken-> SIMT stack | pc and mask | you -pc-> Warp scheduler | fetch and issue -instr-> Operand collector | attaches mask -a, b-> ALU | execute
```

The SIMT stack sits at the **end** of the pipeline and feeds the **start**: it is the loop that closes control flow. It is the block that plays the role of the "PC register" in an ordinary CPU, except that each warp has a small stack of PCs with lane masks instead of one PC.

| Event | Who signals it | What the stack does |
|---|---|---|
| Launch | subcore (`wl_mask`) | one entry: pc = launch PC, mask = all lanes, rpc = 0xFFFFFFFF (never) |
| Ordinary instruction issued | scheduler (`adv_mask`) | top.pc += 4, then pop if it reached its reconvergence point |
| JMP / BEQ / BNE / EXIT | ALU (`br_*`) | jump, split, or remove lanes, then `ctrl_done` |
| Barrier released | barrier (`release_mask`, OR-ed into `adv_mask`) | step past the BAR |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| ALU (10) | br_* in | Delivers the evaluated control instruction and the per-lane taken bits. |
| Warp scheduler (07) | pc, live out; adv_mask in | Fetches at `pc[w]`; tells the stack when an ordinary instruction has issued. |
| Barrier (12) | release_mask into adv_mask and ctrl_done | A released BAR is treated like an ordinary instruction that finished: step the PC, end the control wait. |
| Sub-core (15) | mask out, live out | `mask[is_warp]` becomes the issue mask; `live == 0` (with LSU and SFU idle) ends the workgroup. |
| Statistics | depth, overflow | Maximum divergence depth reached, and whether any branch had to be treated as uniform. |

## Design details

- **An entry is {pc, mask, rpc}.** `pc` is where these lanes are, `mask` is which lanes, and `rpc` is the reconvergence PC: the address where this group should rejoin the others. The top entry is what the warp runs now.
- **Where the join comes from.** The ISA puts the join offset in the branch instruction itself (`f_join`). The compiler (here, the assembler writer) computes the immediate post-dominator of the branch and encodes it. The hardware does not have to find it.
- **Split order.** On a divergent branch, the current top entry becomes the join entry (pc = join), then the not-taken group is pushed, then the taken group. The taken group is on top, so it runs first; when it reaches the join it is popped, then the not-taken group runs, then both are popped and the full mask continues at the join.
- **Saving entries.** An entry whose PC already equals the join would be popped at once, so it is not pushed. And when the top entry already reconverges at the same join (the back-edge of a divergent loop), it is replaced instead of nested. Without that rule each loop iteration would push one more entry and a loop would overflow the stack.
- **EXIT.** The exiting lanes are cleared from *every* entry, not only the top, because those threads must never run again on any path. Entries left with no lanes are popped. An empty stack means the warp is done.
- **Overflow.** If a split would need more than 7 entries, the sticky `overflow` flag is set and the branch is executed as if every lane took it. That is wrong for the not-taken lanes, so overflow is a signal for the programmer, not a feature.
- **Everything in one cycle.** Each warp's update is computed from working copies in one `always_ff` pass, including chains of several pops when nested joins coincide.

## Questions: what if we did it differently?

**Q1. What if we used Volta-style convergence barriers instead of a stack?**
Since Volta, NVIDIA GPUs give each thread its own PC and use explicit convergence barrier instructions (`BSSY`/`BSYNC`) placed by the compiler. Instead of a stack per warp you keep per-thread PCs plus a few barrier masks, and the scheduler picks which group of threads with equal PC to run. Good: diverged groups can interleave, so one group spinning on a lock cannot deadlock another (independent thread scheduling). Bad: more state (8 PCs per warp), a picker that groups threads by PC, and the compiler must place the barriers. The testbench golden model would become a per-thread interpreter with a group-selection rule rather than a golden stack.

**Q2. What about predication instead?**
With predication, each instruction is guarded by a per-lane predicate and both sides of an if/else are simply executed, with lanes masked off. There is no stack and no split, and short branches cost nothing extra. But both paths always run, nested and data-dependent loops become hard, and the ISA needs predicate registers. Real GPUs use predication for short bodies and a stack or barriers for long ones.

**Q3. What about dynamic warp formation (or thread block compaction)?**
After a divergent branch, threads from different warps that took the same path could be regrouped into new, fuller warps. This raises lane utilisation for heavily divergent code. The hardware cost is large: a thread's registers live in a particular lane of the register file, so regrouping needs either a crossbar into the register file or restrictions on which lanes can merge. It also breaks the simple "warp = fixed 8 threads" model that the whole testbench is built on.

**Q4. What if the join PC were found by hardware instead of encoded in the branch?**
The hardware would have to compute the immediate post-dominator, which needs the control-flow graph: not feasible at run time. A cheaper trick is to reconverge at the smaller of the two PCs (the "min-PC" heuristic): run the group with the lower PC first and merge groups when their PCs are equal. It works for structured code but can reconverge late. Encoding the join keeps the hardware small and exact.

**Q5. What if the stack were deeper, or spilled to memory?**
Each extra entry costs 72 bits (32-bit pc, 32-bit rpc, 8-bit mask) for every warp, and the one-cycle update logic grows with depth; real GPUs keep a few entries on chip and spill the rest to memory. Spilling needs a path to the L1 and a way to stall the warp during spill and fill. With `DEPTH = 7` and the loop-reuse rule, our kernels never overflow, so we keep the sticky flag instead.

**Q6. What if the not-taken path ran first?**
Either order is correct as long as both run before the join. Taken-first tends to execute loop bodies first. The testbench checks per-lane traces, which are the same in both orders, so only the golden stack model notices; this is exactly what `BUG_PUSH_ORDER` shows.

**Q7. What does `BUG_NO_POP` break?**
Entries are never popped when they reach their rpc. After the taken group reaches the join, it keeps running past it with only its own lanes, and the not-taken group never gets its turn. The bench reported a PC and mask that did not match the golden stack at all. In a real kernel half the threads would simply never finish their work.

**Q8. What does `BUG_PUSH_ORDER` break?**
The taken and not-taken entries are pushed in the opposite order, so the not-taken lanes run first. Every thread still executes the right instructions, so per-lane results are correct; only the golden stack model, which compares PC and mask each cycle, catches it. It is a "spec violation without wrong answers", the hardest kind to spot.

**Q9. What does `BUG_EXIT_MASK` break?**
EXIT only clears the top entry's mask. Lanes that exit inside a divergent region are still present in the join entry below, so when the stack pops back to it, the exited threads come back to life and run code after their EXIT. The bench saw exited lanes reappear in the mask.
