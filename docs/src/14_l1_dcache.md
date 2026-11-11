# 14 L1 data cache

## What this block is, in plain words

Each SM has a 1 KB data cache close to its LSUs. Reads that hit are answered in one cycle. It is **write-through**: every store goes on to memory (so memory is always up to date), and if the line is in the cache the stored bytes are merged into it too. A store that misses does not bring the line in (**no write-allocate**). Because the two SMs' L1s do not watch each other's writes, both are **invalidated at the start of every kernel**: GPU kernels must not rely on seeing another SM's writes during the same kernel.

## Architecture and RTL decisions

2-way set associative, 16 sets x 32-byte lines, LRU per set.

| Decision | Why |
|---|---|
| Write-through, no write-allocate | No dirty lines in L1: an L1 never has to write anything back, and invalidating it at kernel start is free. The L2 (block 17) does the write-back caching. |
| A write hit merges only strobed bytes | Partial stores must not clobber the rest of the line (`BUG_STRB_MERGE`). |
| Write hit also updates the cached line | Otherwise a later read hits stale data (`BUG_WRITE_NO_UPDATE`). |
| LRU: a hit makes its way most recently used; a fill goes to the LRU way | Correct replacement (`BUG_LRU` always evicts way 0: data stays correct, only hit rate suffers; caught by the exact cache model). |
| Invalidate during a fill: answer, do not install | Same rule as the instruction cache. |

## Verification decisions and why

| Decision | Why |
|---|---|
| Exact model of tags, valid bits and LRU | Predicts hit or miss for every access, so the checker knows exactly which memory requests must appear. |
| Every read compared with true memory contents | Write-through guarantees the cache equals memory, so this is a complete data check. |
| Small address range: 4 sets x 4 tags (conflict test: 1 set x 3 tags) | Forces evictions constantly. |

## Results

| Item | Result |
|---|---|
| Regression | 4 tests x 3 seeds = 12 runs, all PASS (5,000 accesses per random run) |
| Merged coverage | 100% (13 of 13) |
| `BUG_WRITE_NO_UPDATE`, `BUG_LRU`, `BUG_STRB_MERGE` | all caught (536, 2,182 and 413 errors) |

# Teaching section: the L1 data cache in context

## The block and its pins

```pins
block: L1 data cache | l1_dcache.sv · 2-way · 16 sets x 32-byte lines (1 KB in sm.sv) · write-through, no write-allocate
in: req_valid / req_ready | line_arbiter (from the 2 LSUs) | handshake: a line request is offered / cache is idle
in: req_addr, req_we, req_wdata, req_wstrb | line_arbiter | line address, read or write, 256-bit data and 32 byte strobes
in: invalidate | sm (kernel start) | clear every line; a fill in flight is answered but not installed
in: mreq_ready | SM memory arbiter | the path toward the crossbar accepts the request
in: mrsp_valid, mrsp_data | SM memory arbiter | fill data, or the acknowledge of a write
out: rsp_valid, rsp_data | line_arbiter | answer: the line for a read, the acknowledge for a write
out: mreq_valid, mreq_addr, mreq_we, mreq_wdata, mreq_wstrb | SM memory arbiter | a miss fill or a write-through
out: last_hit | sm statistics | whether the last accepted request hit
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the memory path

```hflow
LSU x 2 | coalesced lines -line req-> Line arbiter | round-robin -line req-> L1 data cache | hit or miss | you -miss/write-> Memory arbiter | with I-cache fills -line req-> Crossbar | to L2 banks
```

There is one L1 per SM, shared by its two sub-cores. It sits between the per-sub-core LSUs and the SM's single memory port.

| Access | Hit | Miss |
|---|---|---|
| Read | answer on the next cycle, way becomes most recently used | fetch the line from below, install it in the LRU way, answer |
| Write | merge strobed bytes into the cached copy, and also send the write below; answer after the acknowledge | send the write below only (no allocation); answer after the acknowledge |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Line arbiter `u_l1_arb` in sm.sv (from 2 LSUs) | req_* in, rsp_* out | All LD/ST traffic of both sub-cores, one request at a time. |
| Memory arbiter `u_mem_arb` in sm.sv | mreq_* / mrsp_* | Shares the SM's single port with the instruction cache; leads to the crossbar and L2. |
| SM / top level | invalidate | `kernel_start` in mgpu_top clears the L1 at every new kernel (through `l1_inv`). |
| SM statistics | last_hit | `stat_l1_hit_pulse = l1_rsp_valid && l1_hit` counts hits. |

## Design details

- **Address split.** With 16 sets: bits [4:0] are the byte in the line, bits [8:5] the set index, bits [31:9] the tag. Each set has 2 ways, each with data, tag and valid; one LRU bit per set names the way to replace next.
- **Three states.** S_IDLE does the lookup in the same cycle the request is accepted. A read hit never leaves S_IDLE; the answer is registered, so it appears on the next cycle. Misses and all writes go S_REQ (offer to memory) → S_WAIT (wait for the answer) → S_IDLE.
- **Write-through, no write-allocate.** A write always goes below with its strobes. If the line is present the strobed bytes are merged in (the `merge` function copies only bytes with a strobe bit), so later reads see the new data. A write miss does not bring the line in. The cache never holds dirty data, so it never needs write-backs or a flush.
- **LRU with one bit.** With 2 ways, "least recently used" is exactly one bit: on a hit in way 0 it points to way 1 and vice versa; after a fill it flips to the other way.
- **No coherence between SMs.** Two SMs could cache the same line. Instead of a coherence protocol, the design invalidates both L1s at every kernel start. Inside one kernel, threads of different SMs must not communicate through global memory and expect to see each other's writes.
- **Invalidate during a miss.** The `discard` flag remembers that an invalidate arrived while a fill was in flight; the requester still gets its answer, but the possibly stale line is not installed.
- **Blocking.** `req_ready` is high only in S_IDLE, so a miss stalls the other sub-core's accesses too.

## Questions: what if we did it differently?

**Q1. What if the L1 were write-back instead of write-through?**
Each line would need a dirty bit, evictions of dirty lines would write back, and a kernel-end flush would be needed so the L2 and CPU see the data. Store traffic below the L1 drops a lot when a warp writes the same line many times. What worsens: complexity, and coherence becomes harder, because another SM could read a stale line from L2 while the newest data sits dirty in this L1. Real GPUs mostly keep the L1 write-through for this reason. Testbench: the memory model would see fewer writes and a flush phase, and the checker would have to compare memory only after the flush.

**Q2. What if writes allocated (write-allocate) on a miss?**
A write miss would fetch the line, merge, and install it. Good when a kernel writes and then reads the same data; wasteful for streaming outputs like vector_add's `C[i]`, which are written once and never read, and would push useful lines out. No-write-allocate matches the GPU streaming pattern. Testbench: expected fill requests appear on write misses.

**Q3. What if the cache were non-blocking with MSHRs?**
*Miss status holding registers* record outstanding misses so hits (hit-under-miss) and further misses (miss-under-miss) can proceed. Requests sent below would need ids, the arbiter would need to allow several outstanding requests, and two misses to the same line would merge into one MSHR. Much better latency hiding; more area and many new corner cases (a write to a line with a pending fill). Testbench: a memory model with variable, out-of-order latency and a checker that matches answers by id.

**Q4. Why 2-way with LRU, and what about PLRU, random, or RRIP?**
With 2 ways, LRU is one bit, so it is the cheapest choice too. With 4 or 8 ways true LRU needs an ordering per set; *tree pseudo-LRU* uses ways-1 bits and is nearly as good; *random* needs only an LFSR and avoids pathological patterns; *RRIP* predicts re-reference distance and resists scans of streaming data. Higher associativity reduces conflict misses but adds tag comparators and a wider way mux. Testbench: the reference model must implement the exact same policy, or the checker must only compare data, not hit/miss patterns.

**Q5. What if we added a small victim cache?**
A few fully associative lines that hold recently evicted lines catch conflict misses of a 2-way cache cheaply. Hardware: a CAM lookup in parallel with the sets and a swap path. Testbench: hit/miss expectations change, so a cycle-accurate model must include it.

**Q6. What happens with `BUG_WRITE_NO_UPDATE`?**
A write hit no longer updates the cached copy, although memory below is written. The next read of that line hits and returns the old data. The symptom is a classic stale-read: "store then load the same address returns the old value". Any test that writes and then reads back hot lines finds it.

**Q7. What happens with `BUG_LRU`?**
The LRU bit is forced to 0 on hits and fills, so way 0 is always the victim. Data stays correct (the cache still only returns what it was given), but way 1 is never replaced after its first fill and two lines alternating in a set keep evicting each other. Only a test that checks hit/miss behaviour against a model (the extra fill requests) catches it, which is why the testbench predicts misses.

**Q8. What happens with `BUG_STRB_MERGE`?**
On a write hit the whole 256-bit write data replaces the cached line instead of only the strobed bytes. Because the LSU fills unused slots with zeros, the other words in the cached line become 0 while memory below still has the right values. A later read of a neighbouring word in the same line returns 0.

**Q9. What if L1s were kept coherent with MESI or MOESI instead of being invalidated per kernel?**
Hardware coherence needs per-line state, a snoop or directory in the L2, and invalidate messages through the crossbar. It lets SMs communicate safely inside a kernel. GPUs mostly use *software coherence*: invalidate at kernel or synchronization boundaries, plus atomics performed at L2. That is what we do, and it costs nothing but a rule for the programmer. Testbench for MESI: multi-SM tests that share lines, and protocol assertions on every state transition.
