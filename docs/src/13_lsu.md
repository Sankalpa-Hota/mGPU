# 13 LSU (load/store unit)

## What this block is, in plain words

A warp's load asks for 8 addresses at once, one per lane. Sending 8 separate memory requests would be slow; if the addresses are close together they usually fall in the same 32-byte line. The LSU **coalesces**: it groups the lanes by line and sends one request per distinct line. For loads it then picks each lane's word out of the returned lines; for stores it builds one line write with byte strobes for all the lanes in that line. Shared-memory instructions (LDS / STS) go straight to the shared memory instead.

## Coalescing rule

Repeat until every active lane is served: take the **lowest** unserved lane; every active lane whose address is in the same line is served by one line request. A fully coalesced warp (8 consecutive words in one line) is one request; 8 lanes in 8 different lines are 8 requests. For stores, two lanes writing the same word: the higher lane wins.

## RTL decisions and why

| Decision | Why |
|---|---|
| One memory instruction at a time | Keeps memory order per sub-core trivially correct. |
| Lowest-lane-first grouping | Deterministic; the testbench predicts the exact request sequence. |
| Loads always end with a writeback, even with no active lane | The scoreboard set the pending bit at issue; it must always be cleared. |
| Stores wait for the memory acknowledge before the LSU is free | `wg_done` and EXIT rely on "LSU idle" meaning all stores have landed. |
| Address = a + imm with a signed 18-bit imm | Negative offsets (e.g. stack-like access) work. |

## Verification decisions and why

| Decision | Why |
|---|---|
| The checker predicts the full ordered list of line requests at acceptance (address, write data, strobes) | Checks coalescing exactly: an uncoalesced LSU gives correct data but wrong traffic (`BUG_COALESCE_OFF`). |
| Address patterns: coalesced, one line per lane, all lanes same word, random in 256 B, anywhere, straddling two lines | Each produces a different number of requests (1, 2, up to 8). |
| Number of lines per instruction checked against the DUT's own counter | The performance result is verified, not just observed. |

The first regression showed the "negative offset" bin at 0: the testbench put a 14-bit value into the 18-bit immediate field, so the sign bit was never set. Fixed in the testbench.

## Results

| Item | Result |
|---|---|
| Regression | 3 tests x 3 seeds = 9 runs, all PASS (3,000 memory instructions per random run) |
| Merged coverage | 100% (15 of 15) |
| `BUG_COALESCE_OFF`, `BUG_STRB_LANE`, `BUG_LOAD_WORD` | all caught (7,109, 2,337 and 4,782 errors) |

# Teaching section: the LSU in context

## The block and its pins

```pins
block: LSU | lsu.sv · 8 lanes · one memory instruction at a time · 32-byte line port
in: ex_valid / ex_ready | regfile_collector | handshake: a LD/ST/LDS/STS is offered / LSU is idle and can take it
in: ex_warp, ex_instr, ex_mask | regfile_collector | which warp, the instruction (opcode, rd, imm), which lanes are active
in: ex_a[8], ex_b[8] | regfile_collector | per lane: base address (rs1) and store data (rs2)
in: sm_ready | shared_mem | shared memory accepts the LDS/STS request
in: sm_rsp_valid, sm_rsp_data[8] | shared_mem | shared memory answer (8 loaded words for LDS)
in: mreq_ready | line_arbiter / L1 | the L1 port accepts the line request
in: mrsp_valid, mrsp_data | line_arbiter / L1 | the 256-bit line (load) or the store acknowledge
in: wb_ready | regfile_collector | register file can take the load result
out: sm_valid, sm_we, sm_mask, sm_addr[8], sm_wdata[8] | shared_mem | one 8-lane shared-memory access
out: mreq_valid, mreq_addr, mreq_we, mreq_wdata, mreq_wstrb | line_arbiter / L1 | one coalesced 32-byte line request with byte strobes
out: wb_valid, wb_warp, wb_rd, wb_mask, wb_data[8] | regfile_collector | load result for register rd of this warp
out: busy | subcore | an instruction is still in flight (stores not yet acknowledged)
out: last_lines | subcore statistics | how many line requests the last LD/ST needed
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the memory path

```hflow
Operand collector | addresses and data x 8 lanes -LD/ST-> LSU | coalesce into lines | you -line req-> Line arbiter | 2 sub-cores to 1 -line-> L1 data cache | per SM -miss/write-> Crossbar | to L2 banks
```

The LSU is the **execute stage for memory instructions** (unit 2 in the collector's `unit_of`). It has two very different exits:

| Instruction | Path | What the LSU does |
|---|---|---|
| LDS / STS | shared_mem (on-chip scratchpad of the sub-core) | Sends all 8 lane addresses in one request; the shared memory resolves bank conflicts itself and answers once. |
| LD / ST | L1 port (line requests) | Groups lanes by 32-byte line, sends one request per distinct line, collects words (load) or waits for acknowledges (store). |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Operand collector (09) | ex_* in, wb_* out | Hands over memory instructions with per-lane addresses and store data; receives load results and writes the register file. Write-back port 2 of the collector belongs to the LSU. |
| Shared memory (12) | sm_* | LDS/STS traffic; one request, one answer per instruction. |
| SM line arbiter, then L1 (14) | mreq_* / mrsp_* | LD/ST line traffic. In `subcore.sv` the LSU's mreq port *is* the sub-core's L1 port. |
| Sub-core (15) | busy, last_lines | `busy` keeps `wg_done` from firing while a store is unacknowledged; `last_lines` is a coalescing statistic. |
| Kernels | — | Every `LD`/`ST` of vector_add, saxpy and reduction; `LDS`/`STS` in the reduction's shared-memory tree. |

## Design details

- **Address generation.** In the S_IDLE accept cycle each lane computes `addr = ex_a + imm` and the LSU latches the mask, the store data, the warp and `rd`. From then on the collector is free; the LSU works from its own copy.
- **One instruction at a time.** `ex_ready` is high only in S_IDLE. This keeps program order trivially correct (a later load can never pass an earlier store), at the cost of no memory-level parallelism inside one sub-core.
- **The coalescing loop.** States S_PICK → S_REQ → S_WAIT repeat. In S_PICK the lowest pending lane names the current line (`addr[31:5]`); every pending lane with the same line is put in `serve`, removed from `pend`, and one request goes out. When `pend` is empty the instruction is finished. So 8 lanes reading 8 consecutive words cost 1 request; 8 lanes spread over 8 lines cost 8.
- **Word selection inside a line.** A 32-byte line holds 8 words; address bits [4:2] say which. A load lane takes `mrsp_data[32*addr[4:2] +: 32]`; a store lane places its data at the same slot and sets 4 byte-strobe bits there. If two lanes store to the same word, the higher lane is written last in the loop, so it wins.
- **Stores wait for an acknowledge.** A store request still waits for `mrsp_valid`; that is how the LSU (and through `busy`, the sub-core) knows the write reached the L1/memory side.
- **Loads always write back.** Even with an all-zero mask a load goes to S_WB, so the scoreboard's pending bit for `rd` is cleared and the warp cannot hang.
- **Why 32-byte lines and 256-bit buses.** 8 lanes x 4 bytes = 32 bytes, so a perfectly coalesced warp access is exactly one line, and one bus beat carries it.

## Questions: what if we did it differently?

**Q1. What if the LSU accepted a new instruction while the previous one is still waiting for memory?**
That is a *non-blocking* LSU with a small queue of in-flight instructions. Hardware: a request queue, per-entry state (pending lanes, partial results), and a way to match answers to entries (an id on the line port). Throughput improves a lot when several warps miss at once. What worsens: ordering. A load after a store to the same address must not overtake it, so you need address comparison (a store buffer with forwarding, or a rule like "stall loads while stores are pending to that line"). The testbench would need an id-aware memory model that answers out of order and a checker that enforces the memory-ordering rule rather than a strict request sequence.

**Q2. What if we coalesced at a different granularity, for example 128-byte segments or 4-byte words?**
Per-word requests (no coalescing) are simplest but cost 8 requests per warp access. A larger segment (like older NVIDIA 128-byte segments split into 32-byte sectors) reduces request count for wide warps but wastes bandwidth when only a few words are used. Ours matches line size to warp width, so there is no waste for the common case. Changing it changes `mreq_wdata` width, the strobe width, the L1 line size and the expected request count in the scoreboard of the testbench.

**Q3. Why find lines one by one (serial loop) instead of all at once?**
A parallel coalescer would compare all 8 addresses with each other in one cycle (28 comparators) and produce a list of unique lines. That saves the S_PICK cycles per line but costs area and a longer combinational path, and the requests still leave one per cycle through a single port. With one port the serial loop costs little. A real GPU uses parallel coalescing plus a multi-ported or sectored L1.

**Q4. What happens with `BUG_COALESCE_OFF`?**
`serve` then contains only the first lane found, so each lane gets its own request even when all 8 share a line. Results stay correct, but `last_lines` becomes the number of active lanes and the run is much slower. Only a test that checks request counts (or the `last_lines` statistic) against a model sees it; a pure data check would pass. That is why the LSU test compares the number of line requests.

**Q5. What happens with `BUG_STRB_LANE`?**
Store data and strobes are placed at slot `l` (the lane number) instead of slot `addr[4:2]` (the word in the line). Whenever lane number and word position differ, for example a strided or shifted store, the wrong word in memory is overwritten and the intended word keeps its old value. A unit-stride store starting at a line boundary happens to work, so random offsets are needed to find it.

**Q6. What happens with `BUG_LOAD_WORD`?**
The mirror image on loads: each lane takes word `l` of the returned line instead of word `addr[4:2]`. Aligned unit-stride loads pass; a load at `base+4` or with stride 2 returns neighbours' data. The reference model in the testbench computes each lane's value independently from the address, so it catches this immediately.

**Q7. What if loads bypassed the L1 (cache only in L2), or stores were cached with write-back in L1?**
Those are L1 policy choices, not LSU choices, but the LSU must be ready for them. With a write-back L1 the LSU's store acknowledge would come back faster (on hit), but `busy` would no longer mean "the store reached global memory", so kernel-end would need an explicit L1 flush. With L1 bypass (like `ld.cg` in PTX) the LSU could tag requests with a cache-policy bit and the testbench would need to check that bit.

**Q8. Could shared memory and global memory use the same path?**
Some GPUs have a *unified* L1/shared-memory array where software chooses the split. Then LDS/STS would also become line or bank requests to one structure, and the LSU would need one arbiter instead of two exits. You save SRAM and gain flexibility; you lose the simple fixed latency of a private scratchpad. Testbench changes: one memory model with two address spaces and a configurable split.

**Q9. Why not handle misaligned addresses?**
Bits [1:0] are ignored, so every access is a whole aligned word. Supporting misaligned or byte/halfword access (like RISC-V `lb`/`lh`) means words can cross a line boundary, so one lane may need two lines, and the strobe logic becomes per-byte. Either trap on misalignment (simple, the RISC-V option) or split the access (expensive). The ISA here simply defines word accesses.
