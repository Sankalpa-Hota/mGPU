# 18 MMU (address translation)

## What this block is, in plain words

Programs use **virtual addresses**; DRAM uses **physical addresses**. The MMU translates between them with a **page table** in memory that the driver builds: memory is cut into 4 KB pages and each virtual page can point to any physical page, be read-only, or be missing. Walking the table needs two memory reads, so recent translations are kept in a small **TLB**. If a page is missing, or a write targets a read-only page, the access is refused (**page fault**) and the fault is recorded for the driver.

## Page table format

| Field | Meaning |
|---|---|
| VA[31:22] | index into the level-1 table at PTBR |
| VA[21:12] | index into the level-2 table named by the level-1 entry |
| VA[11:0] | offset in the page |
| PTE[31:12] | physical page number (or the level-2 table) |
| PTE[1] / PTE[0] | W (writable) / V (valid) |

## RTL decisions and why

| Decision | Why |
|---|---|
| Placed below the L2 | The L2 is virtually addressed: translation only happens on misses and writebacks, not on every access. |
| 8-entry fully associative TLB, round-robin replacement | Small, simple, enough for the working sets here. |
| A TLB entry is filled after a valid level-2 read, even if the access then faults on permission | The translation is valid; only this access is not allowed. The checker models the same rule. |
| Faulting accesses never reach memory and answer with `err` and zero data | No unauthorized read or write can happen. |
| First fault latched (`fault_va`, `fault_write`) until cleared | The driver needs the first cause, not the last. |
| `tlb_invalidate` clears all entries | The driver changes tables, then invalidates (`BUG_TLB_NO_INVAL` keeps stale translations). |
| `enable = 0`: PA = VA | Boot: the first commands are fetched before the tables exist. |

## Verification decisions and why

| Decision | Why |
|---|---|
| The testbench builds real two-level tables in its physical memory, with unmapped level-1 regions, invalid pages and read-only pages | Every fault kind happens. |
| Reference translation walks the same tables; a TLB model predicts walks | The exact downstream sequence is predicted: PTE reads only on a TLB miss, then the data access at the right physical address, or nothing on a fault. |
| Remap test: change a mapping in memory, invalidate, use the page again | The new physical page must be used. |
| TLB-thrash test: 24 pages for 8 entries | Replacement every few accesses. |

## Results

| Item | Result |
|---|---|
| Regression | 5 tests x 3 seeds = 15 runs, all PASS (3,000 translations per run) |
| Merged coverage | 100% (14 of 14) |
| `BUG_TLB_NO_INVAL`, `BUG_PERM`, `BUG_PTE_INDEX` | all caught |

# Teaching section: the MMU in context

## The block and its pins

```pins
block: MMU | mmu.sv · 2-level page table · 4 KB pages · 8-entry fully associative TLB
in: enable, ptbr | control registers 0x201, 0x200 | translation on/off, physical base of the level-1 table
in: tlb_invalidate | control register 0x202 | one-cycle pulse: drop every TLB entry
in: fault_clear | control register 0x205 | one-cycle pulse: re-arm the sticky fault record
in: req_valid / req_ready | line arbiter | a 32-byte line request (virtual address) / MMU is idle and can take it
in: req_addr, req_we, req_wdata, req_wstrb | line arbiter | virtual line address, read or write, 256-bit line data, 32 byte strobes
in: mrsp_valid, mrsp_data | GBIF | the line that came back from memory (a page-table line or the real data)
out: rsp_valid, rsp_data, rsp_err | line arbiter | answer to the requester; err = 1 means a fault, data is zero
out: mreq_valid / mreq_ready | GBIF | a physical line request (page-walk read or the translated access)
out: mreq_addr, mreq_we, mreq_wdata, mreq_wstrb | GBIF | physical line address and the write payload
out: fault_valid, fault_va, fault_write | mgpu_top pins mmu_fault, mmu_fault_va | first fault since the last clear: which virtual address, was it a write
out: stat_tlb_hit, stat_walk | perf counters (RBBM) | one-cycle pulses: TLB hit, page walk started
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the memory path

```hflow
L2 banks + CP fetch + SQE | four line requesters -line req-> Line arbiter | picks one -virtual addr-> MMU | translate | you -physical addr-> GBIF | line to AXI burst -AXI4-> DRAM controller | memory array
```

The MMU sits **below the L2**. That is an unusual choice worth noticing: the caches above it are tagged with virtual addresses, and only the traffic that actually misses in the L2 (plus the uncached command-ring and fence traffic) is translated. Everything that leaves the chip is physical.

| Situation | What the MMU does | Extra memory reads |
|---|---|---|
| `enable = 0` | PA = VA, goes straight to the access | 0 |
| TLB hit, permission fine | uses the cached page number | 0 |
| TLB miss | walks level 1, then level 2, installs the entry, then accesses | 2 |
| Level-1 or level-2 PTE invalid, or write to a page without W | answers with `rsp_err = 1`, data zero, never touches memory; records the fault | 0 to 2 |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Line arbiter (in mgpu_top) | req_* in, rsp_* out | Funnels the two L2 banks, the CP ring fetch and the SQE fence writes into the single MMU port, and routes the answer back to whoever asked. |
| L2 banks (17) | rsp_err (via `below_rsp_err`) | Learn that a refill or writeback faulted. |
| GBIF (19) | mreq_* out, mrsp_* in | Carries both the page-walk reads and the translated accesses out to DRAM. |
| Control registers 0x200-0x202, 0x205 | enable, ptbr, tlb_invalidate, fault_clear | Software (through type-4 packets in the ring) sets up and manages translation. |
| CPU / system | mmu_fault, mmu_fault_va top pins | Sees that a fault happened and where. |
| RBBM perf counters | stat_tlb_hit, stat_walk | Count TLB hits and page walks. |

## Design details

- **Address split.** A 32-bit virtual address is cut into three pieces: bits 31-22 (10 bits) pick one of 1024 entries in the level-1 table, bits 21-12 (10 bits) pick one of 1024 entries in a level-2 table, and bits 11-0 are the byte offset inside a 4 KB page. Each PTE is 4 bytes, so each table is exactly 4 KB, one page. That is why the numbers fit together so neatly; it is the classic 32-bit x86 layout.
- **PTE format.** Bits 31-12 are the physical page number, bit 1 is W (writable), bit 0 is V (valid). A level-1 PTE points to a level-2 table; a level-2 PTE maps the page. Only the level-2 W bit is checked for permission.
- **One FSM, one request at a time.** States are IDLE, LOOK, PTE1_REQ/WAIT, PTE2_REQ/WAIT, ACC_REQ/WAIT. `req_ready` is high only in IDLE, so the MMU is a blocking unit: while it walks the page table, every other requester below the L2 waits.
- **Reading a PTE out of a line.** The downstream port only moves 32-byte lines. So a page-walk read fetches the whole line containing the PTE, and the MMU picks the right 32-bit word with address bits 4-2 (eight words per line).
- **TLB.** Eight entries, fully associative: every entry's VPN is compared with the request in parallel in one combinational loop. Replacement is round-robin through a pointer `t_rr`, which is simpler than LRU and good enough at this size. An entry is installed after a successful level-2 read, even if the access then faults on the W bit, so a repeat write faults quickly from the TLB.
- **Faults are answers, not stalls.** A faulting request is answered with `rsp_err = 1` and zero data, so the requester is never left waiting forever. The first fault is latched (`fault_valid`, `fault_va`, `fault_write`) and stays until `fault_clear`; later faults do not overwrite it, so software always sees the first cause.
- **Invalidate.** `tlb_invalidate` clears all valid bits at once. Software must issue it after changing page tables or PTBR, because the TLB is not kept coherent with the tables in memory.

## Questions: what if we did it differently?

**Q1. What if we used a single-level (flat) page table instead of two levels?**
A flat table for a 32-bit space with 4 KB pages needs 2^20 entries of 4 bytes, 4 MB per address space, which is larger than the whole 1 MB DRAM model here. The walk would be one read instead of two, so a TLB miss gets cheaper, and the FSM loses the PTE2 states. The cost is memory: two levels let unused regions of the address space have no level-2 table at all. The testbench's page-table builder would write one big table instead of a tree.

**Q2. What about an inverted or hashed page table?**
An *inverted page table* (one entry per physical frame, as in PowerPC and IA-64 variants) is sized by physical memory, not virtual space, so it is small. Lookup needs a hash of the VPN and then a chain walk on collisions, so the hardware needs a hash function and a variable-length walk loop instead of a fixed two-step walk. Miss latency becomes unpredictable, and sharing pages between address spaces is awkward. The reference model in the testbench would need the same hash and collision rules.

**Q3. What if we supported huge pages (for example 4 MB)?**
Add a "leaf" bit to the level-1 PTE: if set, the walk stops at level 1 and bits 21-0 of the VA become the offset. The TLB entry needs a page-size bit and its compare must ignore VPN bits 21-12 for huge entries. One TLB entry would then cover 1024 times more memory, so big GPU buffers would almost never miss. The cost is wasted memory when a huge page is half-used, and a more complex compare. The testbench would need tests that mix page sizes and check the size-masked compare.

**Q4. Fully associative TLB versus set-associative?**
Fully associative (what we have) compares all 8 entries at once, which is fine at 8 entries but grows in area and delay with the entry count. Real GPU TLBs with hundreds or thousands of entries are set-associative: a few VPN bits pick a set and only the ways in that set are compared. That scales well but can thrash when several hot pages map to the same set. A common real design is a small fully associative L1 TLB backed by a large set-associative L2 TLB. The coverage model would add "set conflict" bins.

**Q5. What if TLB entries were tagged with an ASID (address-space ID)?**
Today a context switch (new PTBR) requires a full `TLB_INVALIDATE`. With an ASID field in each entry and a current-ASID register, entries of different processes can live side by side, and switching just changes the ASID. Hardware cost: a few extra bits per entry and in the compare, plus an invalidate-by-ASID command. Benefit: no cold TLB after every switch. The testbench would need scenarios with two page tables and checks that one ASID never hits another's entries.

**Q6. Fatal faults (ours) versus replayable faults?**
Our MMU answers a fault with an error and keeps going; the faulting access is simply lost. Modern GPUs support *replayable faults*: the faulting request is parked, the driver maps the page (demand paging, unified memory), and the access is retried. That needs a fault buffer that can hold many outstanding faults, a replay path, and a way to stall only the affected warps. It enables oversubscribing memory but adds a lot of control. The test would need a driver model that services faults and checks the replayed data.

**Q7. What if the MMU were non-blocking (hit-under-miss)?**
Now a TLB hit from the L2 must wait while another request walks the table. A non-blocking MMU would keep a small table of outstanding walks (like MSHRs in a cache), serve hits while a walk is in flight, and merge walks for the same page. Throughput improves a lot under mixed traffic. The cost is ordering: responses can come back out of order, so they need IDs, and the arbiter above must route by ID. The scoreboard would have to accept out-of-order responses.

**Q8. Why translate below the L2 instead of before the L1?**
Real GPUs translate near the SM (per-SM L1 TLBs) so caches can be physically tagged and two virtual aliases of one page do not create two cached copies. Translating below the L2 makes the caches virtual: simpler, and translation cost is paid only on misses, but aliases and page-table changes require an L2 flush (register 0x203) as well as a TLB invalidate. It also means faults are reported per line, not per instruction.

**Q9. What does `BUG_PTE_INDEX` break?**
The level-2 index uses VA bits 20-11 instead of 21-12, off by one bit. Pages whose bit 11 or bit 21 matter get the wrong PTE: some translate to the wrong physical page (silent data corruption), some land on invalid PTEs and fault for no reason. With identity mapping only some addresses show it, which is why the bench uses scrambled mappings and compares against a reference walk.

**Q10. What do `BUG_PERM` and `BUG_TLB_NO_INVAL` break?**
`BUG_PERM` skips the W-bit check on both the TLB-hit and walk paths, so a write to a read-only page goes to memory and no fault is recorded: protection is simply gone. `BUG_TLB_NO_INVAL` ignores `tlb_invalidate`, so after software remaps a page the TLB keeps using the old physical page (a stale translation); reads return old data and writes land in the wrong place until the entry happens to be evicted by round-robin. The test for it must remap a page that is currently in the TLB and access it again.
