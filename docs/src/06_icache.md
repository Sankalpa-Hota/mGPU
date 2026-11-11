# 06 Instruction cache

## What this block is, in plain words

Every warp needs its next instruction every few cycles. Going to memory for each one would take tens of cycles, so each SM keeps recently used instructions in a small, fast memory: the **instruction cache**. It is shared by the SM's two sub-cores. If the instruction is there (a **hit**) it is returned on the next cycle; if not (a **miss**) the cache fetches the whole 32-byte line (8 instructions) from memory, keeps it, and answers.

## Where it sits and who talks to it

```hflow
Sub-core 0 scheduler -fetch pc-> I-cache
Sub-core 1 scheduler -fetch pc-> I-cache -line fill-> SM memory port
```

| Who | Talks to | For what | Signals |
|---|---|---|---|
| Each sub-core's warp scheduler | I-cache | fetch the instruction at pc | `req_valid[p]`, `req_ready[p]`, `req_pc[p]`; answer `rsp_valid[p]`, `rsp_instr` |
| I-cache | SM memory port | read one 32-byte line | line port (read only) |
| Kernel start (dispatcher) | I-cache | new kernel code may be in memory: forget everything | `invalidate` |

## Architecture

16 lines x 32 bytes, **direct mapped**: `pc[4:2]` word in the line, `pc[8:5]` line index, `pc[31:9]` tag.

```flow
box: IDLE | grant one port (round-robin); look up the tag
arrow: hit
box: answer next cycle | instruction from the line
back: miss: REQ (line request) -> WAIT (line arrives, installed unless invalidated meanwhile) -> answer
```

## RTL decisions and why

| Decision | Why |
|---|---|
| Direct mapped, 16 lines | Kernels are small loops; a simple cache is enough and its behaviour is easy to predict exactly in the testbench. |
| Blocking: one miss at a time, other port waits | Simple and correct; the scheduler hides the latency by switching warps. |
| Round-robin between the two ports | A sub-core running a tight loop must not starve the other one (planted bug `BUG_FIXED_PRIO`). |
| Tag compare includes the valid bit and all tag bits | Without valid, an invalidated line still hits (`BUG_NO_VALID`); with fewer tag bits two different addresses alias (`BUG_TAG_BITS`). |
| Invalidate during a fill: answer the requester, do not install the line | The line was requested before the code changed; installing it could leave old code in the cache. |
| A request accepted in the same cycle as invalidate is treated as a miss | The new code must be fetched. |

## Waveform (from the simulation)

Smoke test, cycles 2 to 10. Port 0 asks for pc `0xe48` (cycle 2): a miss, so the line `0xe40` is requested (cycle 3) and arrives in cycle 8; port 0 gets its instruction in cycle 9. Port 1 has been waiting since cycle 3 (the cache is blocking) and is accepted in cycle 9: also a miss, so a new line request starts in cycle 10. Column 0 is cycle 2.

```wave
clk        | ppppppppp
req_valid0 | 100000001
req_valid1 | 011111110
mreq_valid | 010000000
mrsp_valid | 000000100
state      | ===....==| IDLE REQ WAIT IDLE REQ
rsp_valid0 | 000000010
```

## Verification decisions and why

**What we check.** Every answer is the instruction at that address in the *current* program; a hit answers exactly one cycle later; a miss causes exactly one line fill for the right line and nothing else causes fills; after invalidate nothing old is returned; neither port waits more than one turn.

| Decision | Why |
|---|---|
| Instruction memory content is a function of address and a **version**; "rewriting the code" bumps the version | Any stale line after an invalidate returns an instruction of the old version, which the checker spots immediately. |
| The checker keeps a **model of the cache contents** (tags, valid bits) | It then knows whether each request must hit or miss, so it can check the hit latency and that misses (and only misses) produce fills: performance bugs, not only data bugs. |
| Code is rewritten only after the fetch drivers are paused and everything is idle | That is the software rule (stop, write code, invalidate). Rewriting under the fetchers would test a situation the spec does not define. |
| Separate invalidate pulses *during* a miss without changing code | Exercises the discard path on its own. |
| Fairness check: a port that loses arbitration must win next time | Catches starvation, which no data check would see. |
| Checker ordering in the invalidate cycle | A testbench bug found here: the checker first applied a same-cycle invalidate to a miss that started in that very cycle. The spec says that fill is fresh and must be installed; the checker was corrected. |

**Coverage (13 bins).** Hits and misses per port, both ports requesting, a port waiting during a miss, conflict eviction, invalidate idle and during a miss, the first miss after invalidate, first and last index, the same line used by the two ports back to back.

**Assertions.** One grant and one answer per cycle, ready only to a requesting port, request and fill held until accepted, fills line aligned.

## Tests

| Test | Purpose |
|---|---|
| `icache_smoke_test` | short random streams |
| `icache_rand_test` | 200 streams over 8 KB of code: many conflicts |
| `icache_stream_test` | long straight-line code in 1 KB: mostly hits |
| `icache_contention_test` | both ports in 512 bytes, no gaps |
| `icache_invalidate_test` | 10 code rewrites + 10 invalidates during misses |

## Results

| Item | Result |
|---|---|
| Regression | 5 tests x 3 seeds = 15 runs, all PASS |
| Merged coverage | 100% (14 of 14) |
| `BUG_NO_VALID` | caught: the checker sees stale hits after invalidate (`request accepted while a miss is in progress`); the test then cannot quiesce and runs into the timeout |
| `BUG_TAG_BITS` | **first missed**, then caught (203 errors) after a stimulus fix, see below |
| `BUG_FIXED_PRIO` | **not observable in this system**, see below |

**What bug injection taught here.**

- `BUG_TAG_BITS` (the tag compare ignores the top tag bit) passed the first regression. All fetch addresses were below 8 KB, so two addresses differing only in bit 31 never met: a stimulus hole that no coverage bin was asking about. Fix: a quarter of the random streams now run in the high-address alias of the same region (`pc | 0x8000_0000`), and a new coverage bin `tag_alias_msb` proves it happens. Lesson: for every address field, make sure stimulus toggles **every** bit, including the high ones.
- `BUG_FIXED_PRIO` (port 0 always wins) passes every test, and that is correct behaviour of the testbench, not a weakness. Each sub-core has at most one fetch in flight: as soon as port 0 is granted it is waiting for its answer, so port 1 always wins the next cycle. Fixed priority cannot starve anybody with such requesters. The round-robin is kept because it costs nothing and protects against a future scheduler with several fetches in flight; the fairness check stays in the bench for that day. Lesson: a planted bug that cannot fail is either a testbench hole or a property the system does not need; working out which is part of the job.

# Teaching section: the I-cache in context

## The block and its pins

```pins
block: I-cache | icache.sv · direct mapped · 16 lines x 32 bytes · 2 ports · hit answers next cycle
in: req_valid[2] / req_ready[2] | warp scheduler (one per sub-core) | handshake: a fetch for a PC is offered / the cache takes it
in: req_pc[2] | warp scheduler | the PC each sub-core wants to fetch
in: invalidate | mgpu_top (kernel launch) | throw away every cached line (new program loaded)
in: mreq_ready | SM memory arbiter | memory can take the line-fill request
in: mrsp_valid, mrsp_data[256] | SM memory arbiter | the 32-byte line coming back from memory
out: rsp_valid[2] | warp scheduler | one-hot: which port's answer is on rsp_instr this cycle
out: rsp_instr | warp scheduler | the 32-bit instruction word (shared by both ports)
out: mreq_valid, mreq_addr | SM memory arbiter | fetch the 32-byte-aligned line containing the missed PC
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the sub-core pipeline

```hflow
SIMT stack | owns each warp's PC -pc-> Warp scheduler | picks a warp to fetch -f_pc-> I-cache | PC to instruction | you -instr-> Warp scheduler | instruction buffer -issue-> Operand collector | reads registers
```

The I-cache is the **fetch stage**. It is not inside a sub-core: there is one I-cache per SM, shared by the two sub-cores. Its two request ports are the two sub-cores' fetch ports. A miss goes out to the SM's memory arbiter, where it competes with the L1 data cache for the single memory port.

| Situation | What happens | Time seen by the scheduler |
|---|---|---|
| Hit | The cache accepts the request and answers on the next clock edge | 1 cycle |
| Miss | The cache goes busy, asks memory for the whole 32-byte line, installs it, and answers | 1 cycle plus however long memory takes |
| Busy with a miss | Neither port is accepted (`req_ready` stays low) | stalls until the fill returns |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Warp scheduler of sub-core 0 (07, inside 15) | req_*[0], rsp_valid[0], rsp_instr | Fetches the next instruction of one of its warps into that warp's one-entry instruction buffer. |
| Warp scheduler of sub-core 1 | req_*[1], rsp_valid[1], rsp_instr | The same, for the other workgroup running on the SM. Both sub-cores usually run the same kernel, so they share lines. |
| SM memory arbiter (`u_mem_arb` in sm.sv) | mreq_*, mrsp_* | Carries line fills to global memory. The I-cache is input 0; the L1 data cache is input 1. I-cache requests are always reads. |
| mgpu_top (22) | invalidate | Cleared when a new program is loaded, so stale instructions from the previous kernel are never executed. |

## Design details

- **Address split.** A 32-bit PC is cut into three fields. `pc[4:2]` picks one of the 8 instructions in a line. `pc[8:5]` (4 bits, because there are 16 lines) is the index: which line slot to look in. The remaining 23 bits `pc[31:9]` are the tag, stored with the line so the cache can tell *which* of the many addresses that share the slot is actually there. Bits `[1:0]` are always zero for aligned instructions.
- **Direct mapped.** Every address has exactly one slot it may live in. The lookup is one tag compare plus one valid bit, which is the cheapest possible hit logic. The price is conflict misses: two hot pieces of code 512 bytes apart (16 lines x 32 bytes) fight over the same slot.
- **Three-state FSM.** `S_IDLE` accepts one request per cycle and checks for a hit. On a miss it remembers the port and PC (`miss_port`, `miss_pc`) and goes to `S_REQ`, where it holds `mreq_valid` until memory says ready, then `S_WAIT` until the line comes back. The fill is written into the line and the requested word is returned to the waiting port at the same time, so the requester does not have to ask again.
- **Blocking cache.** While a miss is outstanding, nothing else is accepted, not even a hit from the other port. This is simple and safe, and with only two requesters (each with at most one fetch in flight) the loss is small.
- **Round-robin between ports.** The `rr` pointer moves to the port after the one just granted, so if both sub-cores ask in the same cycle they take turns.
- **Invalidate, carefully.** `invalidate` clears every valid bit in one cycle. If a fill is in flight at that moment, the `discard` flag is set: the fill still answers its requester (it is waiting for it) but the line is not installed, because it may hold old program bytes.
- **Why 32-byte lines.** The memory port is 256 bits wide, so one memory beat brings exactly one line. Straight-line code then gets 7 free hits after each miss: spatial locality does the prefetching.

## Questions: what if we did it differently?

**Q1. What if the cache were 2-way set-associative instead of direct mapped?**
Each index would hold two lines, each with its own tag and valid bit, plus one LRU bit per set. A lookup compares both tags in parallel and a mux chooses the hitting way. The gain: two hot code regions that map to the same index (a kernel loop and a helper it calls, for example) no longer evict each other, so conflict misses fall. The cost: a second comparator, a wider output mux on the hit path, the LRU update logic, and one fewer index bit (the tag grows by one). The testbench would need a reference model with LRU replacement, and new coverage for "both ways full, replace the LRU way" and "hit in way 1".

**Q2. And fully associative?**
Any line can go anywhere: 16 tag comparators run in parallel (a CAM), and a replacement policy (LRU, pseudo-LRU or random) picks a victim. There are no conflict misses at all, only capacity misses. But 16 comparisons of a 27-bit tag on every fetch is expensive in area and power, and the hit path gets slower. Fully associative is used for tiny structures such as TLBs, not for instruction caches of this size.

**Q3. What if it prefetched the next line on a miss (next-line prefetch)?**
After fetching line N, the cache would also request line N+1 and install it (or hold it in a small stream buffer). GPU kernels are mostly straight-line loops, so the next miss would often already be satisfied. The hardware needs a second outstanding memory request (or a fill queue) and must not let the prefetch block a real demand miss. It costs memory bandwidth that the L1 data cache would rather use. The testbench reference model must allow a line to appear "without being asked for", and the memory model would see extra reads that the checker must not flag as wrong.

**Q4. What if the cache were non-blocking (hit-under-miss)?**
While a miss from sub-core 0 is being filled, a hit from sub-core 1 could still be served. This needs a miss status holding register (MSHR) to remember the outstanding miss, and the response path must handle a hit and a fill finishing in the same cycle (today both share one `rsp_instr` bus). The gain is that one sub-core's miss no longer stalls the other. The bench would need checks that answers can come back to the two ports in a different order than the requests.

**Q5. What if each sub-core had its own private I-cache?**
No arbitration and no blocking between sub-cores, but two copies of the same kernel code, twice the storage, and two fill requests to memory for the same line. Sharing works well here because both sub-cores run the same kernel. Real SMs often have a small private L0 instruction cache per sub-core in front of a shared L1 instruction cache: a two-level design.

**Q6. Bigger lines or more lines?**
More lines (say 64) means one more index bit, a smaller tag, more storage, and fewer capacity misses for large kernels. Longer lines (64 bytes) would need two memory beats per fill, because the memory port is 256 bits; the FSM would have to count beats. Longer lines help straight-line code but waste bandwidth on short code fragments.

**Q7. What does `BUG_TAG_BITS` break?**
The tag compare ignores the top tag bit. Two addresses that differ only in bit 31 then look identical, so the cache returns the instruction of the wrong address: a false hit. Programs that only live in low memory never show it, which is exactly why the first regression missed it. The bench now runs some streams in the high alias of the address space so that bit toggles.

**Q8. What does `BUG_NO_VALID` break?**
The hit test forgets the valid bit and only compares tags. After reset or after `invalidate`, the tag array still holds leftovers (or reset garbage), so a fetch whose tag happens to match is returned straight from a line that is no longer valid. The symptom is executing instructions from the previous kernel right after a new launch. A test that loads program A, invalidates, then loads program B at the same addresses catches it immediately.

**Q9. Why does `BUG_FIXED_PRIO` (port 0 always wins) never fail?**
Each sub-core has at most one fetch outstanding. As soon as port 0 is granted it waits for its answer and stops asking, so port 1 wins the next cycle anyway. Starvation needs a requester that keeps asking every cycle, and this system has none. If the scheduler were changed to keep several fetches in flight (for example, a fetch-ahead buffer of two instructions per warp), fixed priority could starve sub-core 1, and the fairness check in the bench would then fire.
