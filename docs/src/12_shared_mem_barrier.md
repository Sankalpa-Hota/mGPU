# 12 Shared memory and barrier

## What this block is, in plain words

Threads of one workgroup often need to exchange data, for example to add up numbers together. **Shared memory** is a small, fast scratchpad (512 bytes per sub-core) that all threads of the workgroup can read and write. It is split into 8 **banks** so 8 lanes can be served in one cycle, as long as they use different banks. The **barrier** (instruction BAR) makes every warp of the workgroup wait until all of them have arrived, so data written before the barrier is safely visible after it.

## Shared memory: banks and passes

Word w is in bank w % 8. A warp access is served in **passes**: in each pass every bank serves one word, that of the lowest pending lane using that bank; every pending lane asking for that *same* word is served too (reads are broadcast; for writes the highest lane wins). The access takes as many passes as the largest number of **different** words asked from one bank.

| Pattern | Passes |
|---|---|
| lane l uses word base + l (consecutive) | 1 |
| all lanes the same word | 1 (broadcast) |
| lane l uses word base + 8 l (stride 8) | 8 (all lanes in one bank) |

## Barrier rule

A warp executing BAR arrives and waits. When every **live** warp of the workgroup (not exited) has arrived, all waiting warps are released together. Warps that exited do not count; otherwise one early EXIT would deadlock the rest (`BUG_COUNT_EXITED`). The check runs every cycle, so an exit can be what releases the others.

## RTL decisions and why

| Decision | Why |
|---|---|
| Lowest lane chooses the word of its bank; same-word lanes share the pass | The standard broadcast rule (`BUG_NO_BROADCAST` serializes them). |
| Writes in lane order, highest lane last | A defined winner when lanes write one word (`BUG_WRITE_ORDER` lets the lowest win). |
| Addresses wrap modulo 512 bytes | Defined behaviour for any address. |
| Barrier state cleared after each release | Each BAR is a new barrier (`BUG_NO_CLEAR` lets the next one pass at once). |

## Verification decisions and why

| Decision | Why |
|---|---|
| The checker computes the exact number of passes for every access and checks the response cycle | Bank conflicts are a performance property; only an exact cycle check proves the serialization rule (`BUG_NO_CONFLICT` serves all lanes in one cycle and is only caught this way). |
| Address patterns chosen to produce 1, 2-4, 5-7 and 8 passes | Each conflict degree is reached on purpose. |
| Barrier driver plays scripted warps: work, BAR, wait, repeat; some exit early | Exercises releases caused by the last arrival and by an exit. |
| Barrier checker: release exactly one cycle after the cycle in which all live members have arrived, of exactly those warps | Early release (data race) and late release (deadlock or lost performance) are both bugs. |

## Results

| Item | Result |
|---|---|
| Regression | 3 tests x 3 seeds = 9 runs, all PASS (3,000 accesses, about 970 barrier releases per run) |
| Merged coverage | 100% (19 of 19: 12 shared memory + 7 barrier) |
| `BUG_NO_BROADCAST`, `BUG_NO_CONFLICT`, `BUG_WRITE_ORDER`, `BUG_COUNT_EXITED`, `BUG_NO_CLEAR` | all 5 caught (`BUG_COUNT_EXITED` as a deadlock: "barrier workgroups did not finish") |

# Teaching section: shared memory and the barrier in context

## The blocks and their pins

```pins
block: Shared memory | shared_mem.sv · 128 words x 32 bits · 8 banks · one warp access at a time, served in passes
in: req_valid / req_ready | LSU | handshake: an LDS/STS is offered / shared memory is free
in: req_we, req_mask | LSU | store or load; which lanes take part
in: req_addr[8], req_wdata[8] | LSU | byte address per lane (bits [1:0] ignored, wraps at 512 bytes); store data per lane
in: req_warp, req_rd | LSU (tied to 0 in subcore) | tag carried through to the response
out: rsp_valid, rsp_we | LSU | the whole warp access is finished; it was a store or a load
out: rsp_data[8], rsp_mask, rsp_warp, rsp_rd | LSU | loaded words per lane and the carried tags
out: last_passes | statistics | how many passes the last access needed (1 = no bank conflict)
```

```pins
block: Barrier | barrier.sv · 4 warps · one workgroup · exited warps do not count
in: wl_mask | subcore launch logic | a workgroup is launched: clear the barrier state
in: arrive_valid, arrive_warp | regfile_collector (unit 3) | this warp has executed BAR
in: live | simt_stack | warps of the workgroup that have not exited
out: release_mask | simt_stack and warp scheduler | pulse: these warps may continue past BAR
out: waiting | debug | warps currently waiting at the barrier
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where they sit in the sub-core pipeline

```hflow
Operand collector | dispatches LDS/STS -ex-> LSU | address per lane -sm_req-> Shared memory | banked, in passes | you -sm_rsp-> LSU | writes rd
```

```hflow
Operand collector | dispatches BAR -arrive-> Barrier | counts arrivals | you -release_mask-> SIMT stack | pc += 4 -ctrl_done-> Warp scheduler | warp resumes
```

Shared memory is the **memory stage** for LDS and STS: it sits behind the LSU, which turns the instruction into 8 per-lane addresses and sends the result to the register file afterwards. The barrier is a **control** unit: BAR is routed through the collector to unit 3 (always ready), but it produces no data. Its only output, `release_mask`, is OR-ed into both `adv_mask` (step the PC past BAR) and `ctrl_done` (end the warp's control wait in the scheduler).

## Who uses them and for what

| Who | Through which pins | What for |
|---|---|---|
| LSU (13) | shared memory req_* / rsp_* | Sends LDS/STS for a whole warp and waits for the single response. Global LD/ST go to the L1 instead. |
| Statistics (subcore) | last_passes | `stat_smem_passes`: how bad bank conflicts are in a kernel. |
| Operand collector (09) | arrive_* (ex_unit = 3) | Delivers each BAR as an arrival of that warp. |
| SIMT stack (08) | live in; release_mask out | Tells the barrier who is still alive; moves released warps past BAR. |
| Warp scheduler (07) | release_mask as ctrl_done | A warp that issued BAR sits in `ctrl_wait` until it is released. |
| Kernels | — | The reduction kernel: each warp writes partial sums to shared memory, BAR, then reads the other warps' values. |

## Design details

- **Bank mapping.** Word w lives in bank w mod 8 at row w / 8. Consecutive words are in consecutive banks, so 8 lanes reading 8 consecutive words (`base + tid*4`) hit 8 different banks and finish in one pass.
- **Passes.** In each pass every bank serves one word: the word of the lowest pending lane that maps to it. All pending lanes that want that **same** word are served too. Lanes that want a different word in the same bank wait for the next pass. So an access takes as many passes as the largest number of *different* words asked from one bank.
- **Broadcast and write order.** Many lanes reading the same word all get it in one pass (broadcast). Many lanes writing the same word in one pass: the highest lane wins, because the writes are applied in ascending lane order and the last one lands. This makes the result deterministic, as the ISA promises.
- **Whole-warp response.** The response comes back only when every lane is done, plus one cycle. The LSU never sees half an access.
- **Barrier as a bit set.** The barrier keeps one `arrived` bit per warp. It releases when at least one warp has arrived and every *live* warp has arrived. The check is made every cycle, so a warp that exits instead of reaching BAR can be the event that releases the others.
- **Ready for reuse at once.** On release, `arrived` is cleared in the same cycle, so the next BAR in a loop starts a new round.

## Questions: what if we did it differently?

**Q1. What if we avoided conflicts with padding?**
A classic conflict is a column access in a matrix whose row length is a multiple of 8 words: every lane hits the same bank and the access takes 8 passes. Software padding adds one unused word per row (row length 9 instead of 8), so a column walks through all 8 banks. No hardware change is needed, but memory is wasted (1/9 here), and the programmer must remember to do it. The bench would add a directed test showing passes drop from 8 to 1.

**Q2. What about an XOR swizzle in hardware or the compiler?**
Instead of bank = w mod 8, use bank = (w mod 8) XOR (some bits of the row). Both row and column accesses then spread over all banks without wasting memory. The hardware cost is a few XOR gates on the bank index; the reference model and the bank-conflict coverage must use the same function. Modern GPUs (and libraries like CUTLASS) use swizzled layouts this way.

**Q3. What if there were more banks than lanes, or a multiported memory?**
16 banks for 8 lanes would make random conflicts rarer. A true multiported memory (8 read ports) would have no conflicts at all, but its area grows very fast with ports. Banking with single-ported banks plus a crossbar is the standard compromise.

**Q4. What if a conflict replayed only the conflicting lanes in the pipeline, instead of blocking?**
Today shared memory is busy for the whole access and accepts nothing else. A pipelined design could accept the next warp's access while replaying the leftovers of the current one. Throughput rises, but the response order and partial results must be tracked, and the bench would need to accept interleaved responses.

**Q5. What about named barriers or more than one barrier?**
Real GPUs offer several numbered barriers (PTX `bar.sync id, count`), so different subsets of warps can synchronise independently, for example producer and consumer warps. The hardware becomes one arrived set and an expected count per barrier id, and BAR must carry the id and count. Our one counting barrier for the whole workgroup is the simplest case.

**Q6. Counting barrier vs bit-set barrier?**
A counter that counts arrivals up to the number of warps uses fewer bits for large workgroups, but it cannot tell *which* warps arrived, so it cannot easily ignore exited warps or detect a warp arriving twice. With only 4 warps a bit set is tiny and makes the "every live warp has arrived" check a single AND.

**Q7. What does `BUG_NO_BROADCAST` break?**
Lanes that want the same word as the lane already chosen for a bank are not served in that pass. Results stay correct, but every same-word access takes extra passes: 8 lanes reading one word take 8 passes instead of 1. Only the pass-count check sees it: a performance bug.

**Q8. What does `BUG_NO_CONFLICT` break?**
All lanes are served in one pass regardless of banks, as if the memory had 8 ports. Data is correct in simulation (it is just an array), but `last_passes` is always 1, which real banked hardware could never achieve. The cycle-count and pass checks catch it.

**Q9. What does `BUG_WRITE_ORDER` break?**
Writes are applied in descending lane order, so when several lanes store to the same word, the lowest lane wins instead of the highest. That contradicts the spec, and any kernel relying on "the last thread wins" gets a different value. Directed tests with many lanes writing one address catch it.

**Q10. What do `BUG_COUNT_EXITED` and `BUG_NO_CLEAR` break?**
`BUG_COUNT_EXITED` waits for every warp launched in the workgroup, including ones that already exited. If one warp exits early, the others wait forever: a deadlock, seen as "barrier workgroups did not finish". `BUG_NO_CLEAR` forgets to clear `arrived` on release. The release condition then stays true, so `release_mask` keeps pulsing on following cycles, and because it feeds `adv_mask` the SIMT stack keeps stepping those warps' PCs past instructions they never executed; a later BAR is also passed without waiting. Data written before the barrier can be read too early, and the program goes off the rails.
