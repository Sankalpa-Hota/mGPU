# 17 L2 cache (UCHE)

## What this block is, in plain words

The L2 is the big shared cache in front of DRAM. Unlike the L1 it is **write-back**: stores stay in the cache (the line is marked **dirty**) and are written to DRAM only when the line is evicted or the cache is flushed. That saves a lot of DRAM traffic. It is also **write-allocate**: a store that misses brings the line in first (unless it writes the whole line anyway). Each of the two banks is one instance of this block.

## Behaviour

| Request | Action |
|---|---|
| read hit | answer next cycle |
| read miss | if the LRU victim is dirty, write it back; fill the line; answer |
| write hit | merge strobed bytes, mark dirty |
| write miss, whole line | evict if dirty, install the new data directly (no fill: every byte is overwritten) |
| write miss, partial | evict if dirty, fill, merge, mark dirty |
| flush | write back every dirty line and **invalidate everything**, then `flush_done` |
| fill answered with an MMU error | answer zeros, do not install the line |

## RTL decisions and why

| Decision | Why |
|---|---|
| Write-back + write-allocate | The point of an L2: absorb writes. |
| Full-line write miss skips the fill | Saves a useless DRAM read; the decision is taken *before* entering the request state (issue log R7). |
| Flush = clean **and** invalidate | Between kernels the CPU writes DRAM directly; a flush that only cleaned would leave stale copies that the next kernel reads (issue log R9, `BUG_FLUSH_KEEPS_LINES`). |
| Each bank rebuilds victim addresses with its own bank bit | Otherwise bank 1 writes back to bank 0's addresses. |
| Requests blocked while a flush is requested | No new dirty data appears during the flush. |

## Verification decisions and why

| Decision | Why |
|---|---|
| Golden flat memory: every read must return the latest written bytes | The functional contract of any cache. |
| Exact cache-state model (valid, dirty, LRU, data): predicts every writeback (with its data) and every fill | Catches a missing writeback (`BUG_NO_WRITEBACK`), a lost dirty bit (`BUG_DIRTY_NOT_SET`) and a missing fill (`BUG_PARTIAL_NO_FILL`) at the request where they happen. |
| After each flush, DRAM must equal the golden memory | The real proof that write-back data is never lost. |
| The bench runs bank 1 | Bank-bit mistakes are invisible on bank 0. |
| `l2_cpu_writes_test`: after a flush, write new data straight into DRAM, then read | Reproduces the CPU between kernels; a flush that keeps lines returns stale data. |
| Fault test: one line's fill answers with an error | The line must not be installed and must read as zeros. |

## Results

| Item | Result |
|---|---|
| Regression | 5 tests x 3 seeds = 15 runs, all PASS (4,000 requests and up to 9 flushes per run) |
| Merged coverage | 100% (15 of 15) |
| `BUG_NO_WRITEBACK` | caught: `memory request 00001020 we=0, expected 00001820 we=1` (the dirty victim was not written back) |
| `BUG_DIRTY_NOT_SET`, `BUG_PARTIAL_NO_FILL` | caught: expected memory traffic missing |
| `BUG_FLUSH_KEEPS_LINES` | caught by `l2_cpu_writes_test`: `read 000008ac returned wrong data` |
| Real RTL issues found | glitch fill request (R7); flush semantics (R9) |

# Teaching section: the L2 cache in context

## The block and its pins

```pins
block: L2 cache bank | l2_cache.sv · 2 banks in mgpu_top · 2-way · 32 sets x 32-byte lines per bank · write-back, write-allocate
in: req_valid / req_ready | crossbar | handshake: a request for this bank / bank idle and no flush pending
in: req_addr, req_we, req_wdata, req_wstrb, req_id | crossbar | line address, read or write, data, byte strobes, requester id
in: flush_req | control registers (flush_pend) | clean and invalidate the whole bank
in: mreq_ready | below-L2 arbiter | the path to MMU/DRAM accepts the request
in: mrsp_valid, mrsp_data, mrsp_err | below-L2 arbiter / MMU | fill data or write acknowledge; err = address fault
out: rsp_valid, rsp_data, rsp_id | crossbar | answer (line for reads, zeros for writes) with the id echoed
out: flush_done | control registers | one-cycle pulse when the flush is complete
out: mreq_valid, mreq_addr, mreq_we, mreq_wdata | below-L2 arbiter | a fill (read) or a full-line write-back
out: busy | top-level status | the bank is not idle
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the memory path

```hflow
SM L1s and I-caches | via SM ports -line req-> Crossbar | bank by addr bit 5 -req + id-> L2 bank | write-back cache | you -fill / write-back-> Below-L2 arbiter | with CP fetch and fences -line-> MMU and DRAM | translate, AXI4
```

The L2 is the last level of cache, shared by all SMs. Each bank owns every other line. Because L1s are write-through, every store of every SM reaches the L2, so the L2 holds the newest data and is the point where all SMs agree.

| Case | Path through the FSM |
|---|---|
| Read or write hit | S_IDLE → S_LOOKUP → answer |
| Miss, clean or empty victim | S_LOOKUP → S_FILL_REQ → S_FILL_WAIT → S_DONE |
| Miss, dirty victim | S_LOOKUP → S_WB_REQ → S_WB_WAIT → fill as above → S_DONE |
| Write miss covering all 32 bytes | victim handling, then straight to S_DONE (no fill) |
| Flush | S_FLUSH_SCAN over every set and way, S_FLUSH_REQ/WAIT for each dirty line, then `flush_done` |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Crossbar (16) | req_* in, rsp_* out | All SM traffic for this bank's lines; `req_id` lets the answer find its SM. |
| Below-L2 arbiter `u_below_arb` and MMU in mgpu_top | mreq_* / mrsp_* | Fills and write-backs, shared with command-processor fetch and fences; writes always have full strobes. |
| Control registers in mgpu_top | flush_req, flush_done | Writing the flush register sets `flush_pend` for both banks; each bank clears its bit with `flush_done`. |
| Host / driver | indirectly | The CPU writes DRAM directly between kernels, so it flushes the L2 first and nothing stale stays cached. |

## Design details

- **Address split with banks.** Bit 5 chooses the bank (in the crossbar), so inside a bank the set index starts above it: `index = addr[5+BW +: IW]` (bits [10:6] for 32 sets and 2 banks) and the tag is everything above. When writing a victim back, `addr_of` rebuilds the address from tag, index and the bank's own number.
- **Two-cycle lookup.** A request is captured in S_IDLE and compared in S_LOOKUP, so a hit answers two cycles after acceptance. This splits "register the request" from "read the tag arrays", which eases timing.
- **Write-back with dirty bits.** A write hit merges bytes and sets dirty; nothing goes to DRAM. Only when a dirty line is chosen as victim (or flushed) is it written below, as one full line.
- **Write-allocate, with a full-line shortcut.** A write miss installs the line. If all 32 strobes are set (`c_wstrb == '1`) the old contents do not matter, so the fill is skipped; otherwise the line is filled first and the new bytes merged in.
- **Faults.** If the MMU answers with `mrsp_err`, the requester gets zeros and the line is not installed, so a bad translation never pollutes the cache.
- **Flush = clean + invalidate.** The scan visits `2 * SETS` entries (set * 2 + way), writes back dirty ones and clears every valid bit. During a flush `req_ready` is low.
- **One request at a time per bank.** Parallelism comes from having two banks, not from overlapping misses inside a bank.

## Questions: what if we did it differently?

**Q1. What if the L2 were write-through like the L1?**
No dirty bits, no write-backs, no flush scan: much simpler. But every store from every SM would go to DRAM, and DRAM bandwidth is the scarcest resource on a GPU. A write-back last-level cache absorbs repeated writes (like a reduction's partial sums). Testbench: DRAM traffic expectations change and the flush test disappears.

**Q2. What if write misses did not allocate (no-write-allocate)?**
A write miss would go straight to DRAM with strobes. Good for pure streaming output, but partial writes of a line from several SMs (8 lanes from one SM, then more later) would each go to DRAM. Allocating lets the L2 combine them into one later write-back. Testbench: fill/write-back predictions in the reference model change.

**Q3. What if the bank were non-blocking with MSHRs?**
The bank could keep serving hits while a miss waits for DRAM, and track several misses at once. It needs MSHR entries keyed by line address, merging of requests to the same line, and answers in a different order than requests, which the id field already supports. Big win for latency hiding with many SMs. Testbench: random DRAM latency and order-independent answer checking by id.

**Q4. Inclusive, exclusive, or non-inclusive with respect to the L1s?**
Ours is effectively *non-inclusive*: an L1 may hold a line the L2 has evicted. *Inclusive* means an L2 eviction must back-invalidate L1 copies (needs a path from L2 to SMs, but simplifies coherence lookups). *Exclusive* means a line lives in only one level, giving more total capacity but requiring L1 victims to move into L2. Testbench: checks that inclusion holds after every eviction.

**Q5. What about the replacement policy: LRU vs PLRU vs random vs RRIP?**
At 2 ways LRU is one bit per set, like ours. At a realistic 16 ways true LRU is expensive, so tree PLRU or *RRIP* (scan-resistant, good for streaming GPU data) are used. Random needs almost nothing and avoids pathological thrashing. Testbench: the model must use the same policy if it predicts victims (ours does, to catch `BUG_NO_WRITEBACK` by address).

**Q6. What happens with `BUG_NO_WRITEBACK`?**
A dirty victim is simply overwritten by the new line without being written to DRAM. The update is lost; later reads of that address after it is refilled return old data. The test saw `memory request 00001020 we=0, expected 00001820 we=1`: a read fill where a write-back was expected.

**Q7. What happens with `BUG_DIRTY_NOT_SET`?**
A write hit merges data but does not mark the line dirty. When it is evicted it is treated as clean and silently dropped, so the write never reaches DRAM. Same symptom as Q6 but only for lines that were installed by a read and then written.

**Q8. What happens with `BUG_PARTIAL_NO_FILL`?**
Every write miss skips the fill, even a partial one. The installed line has the new bytes but zeros elsewhere, and is dirty, so those zeros eventually overwrite good DRAM data for the rest of the line. A test with partial-line writes (one lane storing) shows "expected fill request missing".

**Q9. What happens with `BUG_FLUSH_KEEPS_LINES`?**
The flush writes dirty lines back but leaves them valid. After the CPU writes new data directly to DRAM, the next kernel hits the stale L2 copy. It was caught by `l2_cpu_writes_test` as `read 000008ac returned wrong data`. This is why the flush must be *clean and invalidate*, not only *clean*.

**Q10. What if the number of banks or the interleaving changed?**
More banks give more parallel bandwidth; interleaving at a coarser granularity (for example every 4 lines) keeps one warp's neighbouring lines in one bank but makes strided conflicts more likely. `NB`, `BW` and `addr_of` handle a power-of-two bank count; the crossbar's `bank_of` must change identically, and the testbench's bank model must agree.
