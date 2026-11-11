# 07 Warp scheduler

## What this block is, in plain words

A sub-core runs up to 4 warps. Each cycle it may start (**issue**) one instruction, and it picks which warp. A warp can only go if its next instruction is fetched and its inputs are ready: an instruction that needs the result of a slow load must wait until the load has written its register. The warp scheduler keeps a small **scoreboard** (one "still being written" bit per register per warp) and picks, round-robin, a warp whose next instruction has no hazard. Switching to another warp while one waits is how a GPU hides memory latency.

## Where it sits and who talks to it

```hflow
SIMT stack -pc, live-> Warp scheduler -fetch pc-> I-cache
Warp scheduler -instruction-> Operand collector
Register file -writeback done-> Warp scheduler
SIMT stack / barrier -control resolved-> Warp scheduler
```

| Who | Talks to | For what | Signals |
|---|---|---|---|
| SIMT stack | scheduler | each warp's pc and whether it is alive | `pc[w]`, `live` |
| Scheduler | I-cache | fetch the next instruction of one warp | `f_valid`, `f_ready`, `f_pc`; `f_rsp_valid`, `f_rsp_instr` |
| Scheduler | operand collector | issue one instruction | `is_valid`, `is_ready`, `is_warp`, `is_instr`, `is_pc` |
| Scheduler | SIMT stack | a non-control instruction issued: pc + 4 | `adv_mask` |
| Register file | scheduler | register written: clear its pending bit | `wb_valid[3]`, `wb_warp`, `wb_rd` |
| SIMT stack, barrier | scheduler | branch / barrier resolved, warp may continue | `ctrl_done` |

## Architecture

```tree
warp_scheduler | per sub-core | root
  Instruction buffer x4 | one fetched instruction per warp | comp
  Fetch arbiter | round-robin over warps with an empty buffer; held while stalled | comp
  Scoreboard x4 | 16 pending bits per warp | comp
  Issue arbiter | round-robin over eligible warps; held while stalled | comp
  Control wait x4 | warp stopped until its branch / barrier / exit is resolved | comp
```

**Hazards.** RAW: a source (`rs1`, or `rs2` / `rd` for stores and branches) is pending. WAW: the destination is pending. EXIT: anything pending.

## RTL decisions and why

| Decision | Why |
|---|---|
| One instruction buffer per warp, one fetch in flight | Enough to keep 4 warps fed at this size; easy to reason about. |
| Scoreboard per register instead of "one instruction per warp in flight" | Independent instructions of the same warp can overlap with a slow load. |
| WAW check | Two writes to the same register may finish out of order (SFU slow, ALU fast); the older one would overwrite the newer (`BUG_NO_WAW`). |
| **EXIT waits for every pending write** | Otherwise a late writeback lands after the warp is gone, possibly in a relaunched warp (issue log R5). |
| Control instructions stop the warp until `ctrl_done` | The next pc is unknown until the branch is evaluated; no speculation keeps the design simple. |
| Issue and fetch requests are **held** while not accepted | valid/ready rule. The fetch hold was missing in the first version and found by SVA (issue log R3); planted as `BUG_NO_HOLD` for issue. |
| A fetch answer for a warp that died or was relaunched is dropped | Issue log R4. |
| Round-robin pointers advance after each grant | No warp starves (`BUG_RR_STUCK`). |

## Waveform (from the simulation)

Smoke test, cycles 4 to 12. All 4 warps are launched (cycle 4); warp 0's instruction is fetched and arrives in cycle 6; it is offered in cycle 7 but the collector is busy until cycle 9 (issue held); in cycle 10 its destination is marked pending in the scoreboard (`pend0` bit 5). Warp 1 issues in cycle 11.

```wave
clk      | ppppppppp
f_valid  | 010110011
f_rsp    | 001000100
is_valid | 000111010
is_ready | 111001111
is_warp  | xxx===x=x| 0 0 0 1
adv      | 000001010
```

## Verification decisions and why

**What we check.** Every issued instruction is exactly the program's instruction at the warp's current pc, from a live warp that is not waiting, with no RAW / WAW hazard, and EXIT only with nothing pending; an eligible warp is never passed over more than 4 times.

| Decision | Why |
|---|---|
| The environment is fully **reactive**: fetch, SIMT and execution models answer the DUT | A scheduler has no "input transactions" of its own; its behaviour emerges from the timing of everything around it. |
| The program is a pure function of the pc (and a seed) | The checker can always recompute what must be issued, even after random jumps. |
| Execution model returns writebacks after random latencies on 3 ports (ALU fast, SFU and LSU slow) | Out-of-order completion is what makes WAW and EXIT hazards real. |
| A small register span (3-6 registers) in the hazard test | Collisions on registers become frequent. |
| The checker reads the scheduler's buffers (white box) for coverage only | "RAW stall happened" is invisible on the pins; checks stay black box. |
| End of test: no relaunch; the SIMT model resolves every control instruction as an exit | Random programs can loop forever; the drain must be guaranteed to end (a testbench bug found in the first regression). |

**Coverage (15 bins).** Issue from each warp; RAW, WAW and EXIT-waits stalls; waiting for control; all 4 warps eligible; issue and fetch backpressure; 2 and 3 writebacks in one cycle; the same warp twice in a row; relaunch. A bin "writeback and set of the same register in one cycle" was removed: the WAW check makes it unreachable.

**Assertions.** Issue and fetch held until accepted, pc advance only on issue, no X.

## Tests

`ws_smoke_test`, `ws_rand_test` (20,000 cycles), `ws_hazard_test` (3 registers, slow units), `ws_throughput_test` (everything ready, short latencies), `ws_backpressure_test` (collector ready 20%), `ws_control_test` (30% control instructions).

## Results

| Item | Result |
|---|---|
| Regression | 6 tests x 3 seeds = 18 runs, all PASS |
| Merged coverage | 100% (15 of 15) |
| `BUG_NO_WAW` | caught: `WAW hazard: warp 3 issued 1c48a0bb while r1 pending` |
| `BUG_NO_HOLD` | caught by SVA: `fetch request changed before it was accepted` |
| `BUG_RR_STUCK` | caught: `warp 3 eligible but passed over 5 times (starvation)` |
| Real RTL issues found | fetch request not held (R3), stale fetch after relaunch (R4), EXIT with pending writes (R5): see the issue log |

# Teaching section: the warp scheduler in context

## The block and its pins

```pins
block: Warp scheduler | warp_scheduler.sv · 4 warps · 1-entry buffer per warp · round-robin fetch and issue
in: wl_mask | subcore launch logic | which warps are (re)launched this cycle: drop their old state
in: live, pc[4] | simt_stack | which warps still exist, and each warp's current PC
in: f_rsp_valid, f_rsp_instr | icache | the fetched instruction word
in: wb_valid[3], wb_warp[3], wb_rd[3] | ALU, SFU, LSU write-backs | a register was written: clear its pending bit
in: ctrl_done | simt_stack and barrier | a branch / JMP / EXIT / BAR of this warp has been resolved
out: f_valid / f_ready, f_pc | icache | handshake: fetch the instruction at this PC
out: is_valid / is_ready | regfile_collector | handshake: an instruction is issued / the collector can take it
out: is_warp, is_instr, is_pc | regfile_collector | which warp, the instruction word, and its PC
out: adv_mask | simt_stack | a non-control instruction was issued: move that warp's PC forward by 4
out: elig, idle | debug and statistics | warps that could issue now; nothing buffered, fetching or waiting
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the sub-core pipeline

```hflow
SIMT stack | pc and live per warp -pc-> Warp scheduler | fetch and issue | you -f_pc-> I-cache | returns instr -instr-> Warp scheduler | instruction buffer -issue-> Operand collector | reads registers
```

The warp scheduler is really two small stages in one block:

| Part | Stage | Job |
|---|---|---|
| Fetch half | fetch | Picks a live warp whose instruction buffer is empty, sends its PC to the I-cache, and puts the answer into that warp's buffer. One fetch in flight at a time. |
| Issue half | issue / decode | Among the warps whose buffered instruction has no hazard, picks one (round-robin) and hands it to the operand collector. |

The scheduler does **not** own the PCs. The SIMT stack does; the scheduler only reads `pc[]` and tells the stack to move forward with `adv_mask`.

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| SIMT stack (08) | live, pc in; adv_mask out | The stack says which warps exist and where they are; the scheduler says "this warp issued an ordinary instruction, step its PC". |
| I-cache (06, in sm.sv) | f_* | Fetches the instruction word for a PC. |
| Operand collector (09) | is_* | Receives the issued instruction. The sub-core adds the warp's active mask (`mask[is_warp]`) on the way. |
| ALU, SFU, LSU (10, 11, 13) | wb_* (snooped) | The sub-core feeds the three write-back ports that actually fired (`wbv & wbr`) back in, so the scoreboard can clear pending bits. |
| SIMT stack and barrier (08, 12) | ctrl_done | `simt_done | release_mask`: a branch was resolved, or a barrier released the warp. |
| Sub-core (15) | elig, issue count | `stat_issue` counts issued instructions for the performance statistics. |

## Design details

- **One-entry instruction buffer per warp.** Each warp holds at most one fetched instruction (`ibuf_v`, `ibuf_instr`, `ibuf_pc`). Fetch fills it, issue empties it. A warp is only fetched again after its instruction has issued, so the buffer is never stale for straight-line code.
- **Scoreboard.** Each warp has 16 pending bits, one per register. Issuing an instruction that writes `rd` sets that bit; a write-back for that warp and register clears it. If both happen in the same cycle, the set wins, because the newer instruction still has to write.
- **Hazard rule.** An instruction may issue only if none of its source registers is pending (read-after-write, RAW) and its destination is not pending (write-after-write, WAW). EXIT additionally waits until *every* pending bit is clear, so no late write-back can land in a warp that has been relaunched.
- **Control instructions stop the warp.** After a branch, JMP, BAR or EXIT issues, the warp sets `ctrl_wait` and is neither fetched nor issued until `ctrl_done` says the new PC is known. This is the simplest way to avoid fetching the wrong path: no prediction, no flush. Other warps keep the pipeline busy in the meantime.
- **Round-robin pointers.** Fetch and issue each have a pointer (`f_rr`, `i_rr`) that starts searching from the warp after the last one served. Every eligible warp is guaranteed a turn within 4 cycles.
- **Valid/ready hold.** Once `f_valid` or `is_valid` is raised for a warp and not accepted, the same warp is offered again next cycle (`f_hold`, `i_hold`), even if the round-robin would now prefer another. That is the AXI-style rule: a request must not change while it waits.
- **Stale fetches.** If a warp dies or is relaunched while its fetch is in flight, `f_stale` is set and the answer is thrown away instead of being put in the buffer.

## Questions: what if we did it differently?

**Q1. What if issue used greedy-then-oldest (GTO) instead of loose round-robin?**
GTO keeps issuing from the same warp as long as it can, and only when it stalls switches to the oldest ready warp. The hardware needs an age order of warps (a small age matrix or launch timestamps) instead of a rotating pointer. Good: one warp runs ahead and reuses its cache lines while they are still in the cache, so cache locality improves. Bad: warps drift apart, so barriers wait longer, and memory accesses are less spread out in time. The testbench's "eligible but passed over N times" starvation check would have to be relaxed, because GTO intentionally lets a warp wait while another runs.

**Q2. What about two-level scheduling?**
Warps are split into a small active set that the issue logic picks from, and a pending set of warps waiting on long-latency loads. A warp that issues a load moves to the pending set; a ready one moves in. The issue picker becomes smaller and faster, and warps hit their long stalls at different times instead of all at once. It needs extra queue logic and a policy for moving warps. With only 4 warps here, it would not pay off.

**Q3. What if the instruction buffer held two instructions per warp (fetch-ahead)?**
Fetch could run one instruction ahead, hiding the I-cache's 1-cycle hit latency, so a single warp could issue back-to-back. The buffer becomes a small FIFO, and after a taken branch the second entry must be flushed. Several fetches could then be in flight, which would make the I-cache's fixed-priority bug a real starvation risk. The bench reference model would need to model the FIFO and flushes.

**Q4. What if we used a full register-count scoreboard or operand forwarding instead of pending bits?**
Pending bits allow only one outstanding write per register, which is why WAW stalls. A counter per register (as some GPUs use) would allow several outstanding writes to the same register, but then results must come back in order. Forwarding from the ALU result straight to the next instruction would remove the RAW wait for back-to-back ALU ops, but GPUs rarely forward: they cover latency with other warps instead, and forwarding paths 8 lanes wide are expensive.

**Q5. What if branches were predicted instead of stopping the warp?**
The scheduler would keep fetching along a guessed path and flush the buffer on a wrong guess. On a GPU the stall is already hidden by other warps, and divergence (some lanes taken, some not) means there is no single right path to predict anyway. `ctrl_wait` is cheaper and never wrong.

**Q6. What if the scheduler could issue two instructions per cycle (dual issue)?**
It would need two pickers, two hazard checks that also check the two picked instructions against each other, and a collector that can accept two. Real SMs dual-issue to different units (an ALU op and a load together). Throughput can go up, but the collector and register file would need more read ports, which is the expensive part.

**Q7. What does `BUG_NO_WAW` break?**
The destination register is no longer checked. If an SFU DIV to r1 (32 cycles) is still running and an ADD to r1 issues, the ADD finishes first and the DIV overwrites it later. The program sees the old, wrong value. The bench caught it as "WAW hazard: warp 3 issued ... while r1 pending".

**Q8. What does `BUG_NO_HOLD` break?**
The fetch and issue requests may change warp while waiting for ready. That violates the valid/ready protocol: the I-cache might accept a request for a PC that was never the one it saw on the previous cycle, or the collector may get a different instruction than the one the scheduler cleared from its buffer. An SVA assertion ("fetch request changed before it was accepted") catches it immediately.

**Q9. What does `BUG_RR_STUCK` break?**
The issue pointer never moves, so the search always starts from the same warp. A warp sitting earlier in the search order wins every time it is ready, and others can wait a long time. Results stay correct, so only a fairness check ("eligible but passed over 5 times") finds it: a reminder that performance bugs need their own checkers.
