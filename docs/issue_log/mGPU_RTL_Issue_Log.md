# mGPU RTL issue log

## How to read this log

Every entry is a real problem found while verifying mGPU, not a planted `BUG_*` (those are listed in each block's own document). Each entry answers the same questions:

| Question | What it tells you |
|---|---|
| **Symptom** | What the failing log or the review showed |
| **Root cause** | Why the RTL was wrong |
| **Fix** | What changed in the RTL |
| **Caught by** | The exact test, seed and check, or "design review" when no test was needed |
| **How to think of it** | The habit of mind that finds this class of bug before a test does |
| **Other ways to catch it** | Every other technique that would have found it |

The testbench mistakes found along the way are in the appendix. They are just as instructive, because a wrong testbench hides real bugs.

## Summary

| # | Block | Issue | Found by |
|---|---|---|---|
| R1 | 01/03 decoder + SQE | A zero-payload WAIT_FOR_IDLE could never reach the SQE | design review of the block-to-block interface |
| R2 | 03 SQE | Unknown opcode broke the accept / execute / done protocol | SVA `a_hold_input`, `a_done_pulse` in `sqe_unknown_op_test` |
| R3 | 07 warp scheduler | Fetch request changed while waiting for `f_ready` | SVA `a_fetch_hold` in `ws_backpressure_test` and others |
| R4 | 07 warp scheduler | Fetch answer could land in a warp that was relaunched meanwhile | design review while writing the SIMT model |
| R5 | 07 warp scheduler | A warp could EXIT with register writes still in flight | design review while writing the execution model |
| R6 | 08 SIMT stack | Every divergent loop iteration grew the stack until it overflowed | golden-model mismatch in `simt_rand_test` seed 1 |
| R7 | 17 L2 cache | A full-line write miss offered a fill request for one cycle and then withdrew it | SVA `a_req_hold` + checker "unexpected memory request" in `l2_rand_test` |
| R8 | 20 DRAM controller | RDATA came straight from the memory array and changed while a stalled read beat waited for RREADY | AXI protocol checker `a_r_stable` in `dram_rand_test` |
| R9 | 17 L2 cache (system) | Flush only cleaned dirty lines; lines stayed valid, so after the CPU wrote DRAM directly the next kernel read stale code and data | design review at full-chip integration; now `l2_cpu_writes_test` |
| R10 | 22 top (system) | Command fetch and fence writes went through the write-back L2: stale commands, fences invisible to the CPU | design review at full-chip integration |

%%MORE%%

## R1. WAIT_FOR_IDLE with no payload never reaches the SQE (blocks 01 and 03)

**Symptom.** None in simulation: the issue was found before the SQE existed. The overview's example ring used `0x70030000`, a type 7 WAIT_FOR_IDLE with count 0.

**Root cause.** The packet decoder (block 01) only produces output for **payload** dwords; a header with count 0 is consumed silently (that is correct and verified behaviour). The SQE (block 03) only learns about an operation from its payload dwords. So a zero-count operation is invisible to the SQE: the driver would believe it waited for idle, and the GPU would not wait at all. Each block was correct on its own; the bug was in the **contract between them**.

**Fix.** Every type 7 operation carries at least one payload dword. WAIT_FOR_IDLE now carries a busy mask (which blocks to wait for), which is also more useful.

**Caught by.** Design review: writing down "who sends what to whom" for the SQE showed that `op_valid` is never raised for a zero-count packet.

**How to think of it.** For every message type, trace it end to end through every block and ask: *at which block does it become visible, and can it ever be dropped on the way?* Corner values (count 0, empty packet, zero-length burst) are where one block's "nothing to do" becomes the next block's "never happened".

**Other ways to catch it.**

- An integration test (decoder + SQE) with WAIT_FOR_IDLE after a long DISPATCH: the fence would be written while work is still running; a scoreboard checking "fence only after the dispatched work ended" fails.
- Cross-block coverage: "SQE executed every opcode the driver sent" would show WAIT_FOR_IDLE at 0 hits.
- An end-to-end assertion: every type 7 header accepted by the decoder is followed by exactly one `op_done`.

## R2. Unknown opcode broke the SQE's protocol (block 03)

**Symptom.** `sqe_unknown_op_test` failed on all three seeds (45 to 59 errors): `[SVA] op_done longer than one cycle` and `[SVA] op_ready high while an operation executes`.

**Root cause.** Every known opcode leaves the COLLECT state and comes back, so `op_ready` drops for at least one cycle and `op_done` is a single pulse. The unknown-opcode path was written as a shortcut: set `bad_op`, pulse `op_done`, and stay in COLLECT. Two unknown opcodes back to back then produced `op_done` on two consecutive cycles (counted as one long pulse), and `op_ready` never dropped after a last payload dword. Downstream logic (perf counters counting `op_done` pulses, the "one operation at a time" rule) would miscount.

**Fix.** A one-cycle `S_DROP` state, so the unknown opcode follows exactly the same accept / execute / done pattern as every other operation.

**Caught by.** The SVA properties `a_done_pulse` and `a_hold_input` in `sqe_unknown_op_test` (15% unknown opcodes). The scoreboard did **not** catch it: the side effects (none, plus `bad_op`) were correct; only the protocol shape was wrong.

**How to think of it.** Error paths and "do nothing" paths are written last and tested least. For every FSM, list the protocol promises (pulse widths, ready dropping, one-at-a-time) and check that the error path keeps **all** of them, not just the functional result. Shortcut paths that skip a state are a red flag.

**Other ways to catch it.**

- Formal: `a_done_pulse` is a two-cycle property; a model checker proves or breaks it in seconds with no stimulus.
- Coverage: "two unknown opcodes back to back" as a cross bin would point at the corner even without the assertion.
- Code review checklist: "every state transition out of COLLECT goes through an execute state".

## R3. Fetch request changed while stalled (block 07)

**Symptom.** In the first warp-scheduler regression, 13 of 18 runs failed with `[SVA] fetch request changed before it was accepted` (most in `ws_backpressure_test`, where the I-cache is ready only 40% of the time).

**Root cause.** The fetch arbiter picks the next warp round-robin **combinationally**, every cycle. While `f_valid` waited for `f_ready`, the set of candidate warps could change (a warp relaunched, another warp's buffer emptied), so the arbiter picked a different warp and `f_pc` changed under a pending request. That breaks the valid/ready rule: the I-cache may already have started on the old address. The issue port had a hold register for exactly this reason; the fetch port did not.

**Fix.** A hold flag and a saved selection (`f_hold`, `f_sel_q`): once a fetch is offered, the same warp and pc stay on the bus until accepted. If that warp dies or is relaunched while waiting, the request still completes and its answer is dropped (`f_stale`).

**Caught by.** The SVA `a_fetch_hold` (`(f_valid && !f_ready) |=> f_valid && $stable(f_pc)`) in every test with fetch backpressure. The scoreboard would only have seen it indirectly, as an occasional wrong instruction.

**How to think of it.** Any `valid` driven from a **combinational arbiter** is suspect: arbiters re-decide every cycle, valid/ready requires the decision to freeze while waiting. Whenever you see "pick = f(requests)" feeding a valid/ready output, look for the hold register.

**Other ways to catch it.**

- Formal proof of the same property on the scheduler alone (small state space).
- A protocol VIP or a generic valid/ready checker bound to every valid/ready interface in the design, automatically.
- Directed test: stall `f_ready` while relaunching warps.

## R4. Stale fetch answer after a warp is relaunched (block 07)

**Symptom.** None in simulation (found before the first run).

**Root cause.** A fetch takes several cycles. If the warp is killed and a new warp is launched in the same slot while the fetch is in flight, the answer belongs to the old warp's pc but would be written into the new warp's instruction buffer: the new warp would execute an instruction from the old program.

**Fix.** `f_stale`: set when the fetched warp dies or is relaunched while its fetch is outstanding; a stale answer is dropped.

**Caught by.** Design review while writing the SIMT model, which relaunches dead warps after a few cycles: "what happens to things in flight for a slot that gets reused?"

**How to think of it.** Every resource that is **reused** (warp slots, MSHR entries, transaction IDs, buffer entries) needs an answer to "what about responses still in flight for the previous user?". Typical fixes: a stale/kill bit, a generation counter in the tag, or waiting until nothing is in flight before reuse.

**Other ways to catch it.**

- The warp scheduler checker compares every issued instruction with the program at that pc; a test with frequent relaunches and slow fetches would report a mismatch.
- Coverage bin "relaunch while fetch outstanding" makes sure the case is really exercised.

## R5. EXIT with register writes still in flight (block 07)

**Symptom.** None in simulation (found while writing the execution model).

**Root cause.** EXIT only waited for its own operands (it has none). A long-latency load or divide issued just before EXIT could still be in flight when the warp finished. When the slot is relaunched, that late writeback would clear a pending bit (or, at sub-core level, write a register) of the **new** warp. The workgroup could also be reported done while its stores are still in flight.

**Fix.** EXIT is a hazard as long as the warp has **any** pending register write (`if (op == EXIT) hazard |= (pend != 0)`). The checker gained the rule "EXIT issued with pending writes" and the coverage bin `exit_waits_for_pending` (hit thousands of times per regression).

**Caught by.** Design review while writing the execution model, which completes writebacks out of order with up to 40 cycles of latency.

**How to think of it.** For every "end of life" event (EXIT, kernel done, reset, power-down, context switch) ask: *is anything still in flight that belongs to me?* The answer is almost always "yes, unless I wait". Same family as R4.

**Other ways to catch it.**

- Full-SM test (block 15) with a load immediately before EXIT and a fast relaunch.
- An assertion: no writeback for a warp that is not live.
- A drain check at workgroup completion: outstanding writes per warp must be 0.

## R6. Divergent loops grew the SIMT stack until it overflowed (block 08)

**Symptom.** `simt_rand_test` seed 1 reported that the golden model predicted a stack overflow on a program with only three levels of nesting, which should fit easily in 7 entries.

**Root cause.** The first stack followed the textbook rule literally: on every divergent branch, turn the top entry into a reconvergence entry and push two entries (not-taken and taken). In a loop, the backward branch diverges on **every** iteration where some lanes leave the loop. Each such iteration pushed two more entries, one of them (the not-taken path) already sitting at the reconvergence pc. A loop where lanes leave one at a time over 4 iterations used 8 entries for a single level of nesting.

**Fix.** Two standard refinements of the post-dominator stack:

1. Never push an entry whose pc already equals the join (it would only pop again).
2. If the top entry already reconverges at the same join (`top.rpc == join`, which is exactly the case of a loop branch inside its own loop), **replace** the top entry instead of nesting a new level.

A divergent loop now uses constant stack space, and the planted bugs (`BUG_NO_POP`, `BUG_PUSH_ORDER`, `BUG_EXIT_MASK`) are still caught.

**Caught by.** The golden PDOM model in the SIMT checker, which had the same flaw and predicted the overflow, combined with reading the program: a three-level program should never overflow. The per-lane semantic check alone would **not** have caught it: overflow handling kept lanes running, just with wrong grouping.

**How to think of it.** For every structure that grows (stacks, queues, credit counters, ID pools), ask *what bounds it?* Then try the input that repeats the growing operation without the shrinking one: loops, retries, back-to-back events. A bound that depends on nesting depth must not also depend on iteration count.

**Other ways to catch it.**

- A coverage or statistics check on maximum stack depth per program, compared with the nesting depth.
- An assertion that stack depth never exceeds 1 + 2 x (static nesting depth) for generated programs.
- A directed test: a single loop where one lane leaves per iteration.

## R7. L2 offered a fill request and then withdrew it (block 17)

**Symptom.** The very first L2 runs failed: `[SVA] memory request changed before accepted` (many times) and `[CHK] unexpected memory request 00000820 we=0`.

**Root cause.** A write that covers the whole 32-byte line does not need the old line from memory (every byte is overwritten), so the design skips the fill. But the decision was made **inside** the `S_FILL_REQ` state, and `mreq_valid` is decoded from that state. For one cycle the bank therefore raised `mreq_valid` for a fill it did not want, then left the state. If memory happened to be ready in that cycle, a real read was issued (the checker's "unexpected memory request"); if not, the request vanished without a handshake (the SVA).

**Fix.** The fill-or-skip decision (`skip_fill`) is made before entering `S_FILL_REQ`, in the states that lead to it (`S_LOOKUP` and `S_WB_WAIT`); a full-line write goes straight to `S_DONE`. `S_FILL_REQ` now only ever means "a fill is wanted".

**Caught by.** Both independent checkers in `l2_rand_test`, `l2_eviction_test` and `l2_fault_test`: the valid/ready assertion `a_req_hold`, and the cache-state model, which predicts the exact list of memory requests and flagged a fill that should not exist.

**How to think of it.** When an output is decoded from a state (`valid = (state == X)`), every path through state X must want that output. A "skip" decision inside a request state is the classic way to produce a one-cycle glitch request. Decide **before** entering the state.

**Other ways to catch it.**

- A formal property: `mreq_valid |-> fill_wanted`.
- Lint or review rule: no early exit from a state that drives a valid.
- A performance counter comparison: fills per full-line write miss must be 0.

## R8. DRAM read data changed while the beat was stalled (block 20)

**Symptom.** `dram_rand_test` failed with `[AXI] R changed or dropped before RREADY`, three times in a 4,000-burst run.

**Root cause.** RDATA was a combinational read of the memory array at the current beat address: `rdata = mem[r_addr]`. While a read beat waits for RREADY (the master is busy), the write channel keeps working. When a write to the very same word completed during that wait, the array changed and so did RDATA, while RVALID was still high. AXI requires the payload of a valid beat to stay constant until it is accepted; a master that samples late would see a different value from one that samples early.

**Fix.** Each read beat is captured into a register (`rdata_q`) when it is offered (entering the data state, and when moving to the next beat); RDATA is that register. The value can no longer change while RREADY is low. Planted as `BUG_RDATA_LIVE` so the regression proves the check stays alive.

**Caught by.** The generic AXI protocol checker (`a_r_stable`), shared by blocks 19 and 20, in `dram_rand_test`, where reads and writes run concurrently and often hit the same row. The data scoreboard alone would not have caught it: the value the master finally took was a legal value (the old or the new data), just not a stable one.

**How to think of it.** Any output that must be *held* (valid/ready payload) and is computed combinationally from storage that something else can write is a hazard. Ask: *what else can change the source of this output while it is waiting?* If anything can, register it at the moment it is offered.

**Other ways to catch it.**

- A directed test: stall RREADY for many cycles while writing the same word.
- Formal: prove `$stable(rdata)` while `rvalid && !rready`, with writes unconstrained.
- Design rule in review: every valid/ready payload comes from a register, or from logic whose inputs are frozen while valid is high.

## R9. L2 flush left stale lines behind (block 17, found at system level)

**Symptom.** None in simulation: found while writing the driver sequence for the full chip.

**Root cause.** The L2 flush wrote back dirty lines and marked them clean, but kept them valid. That is fine for "make DRAM up to date" (what the block bench checked), but not for the second half of the contract: between kernels the CPU writes **new** code and data straight into DRAM. Clean but still-valid lines hold the **old** values, so the next kernel would hit in the L2 and read the previous kernel's code and data. The block was correct against its own specification; the specification was wrong for the system.

**Fix.** Flush is now *clean and invalidate*: every line is written back if dirty and then marked invalid. Planted as `BUG_FLUSH_KEEPS_LINES` and caught by the new `l2_cpu_writes_test`, which writes DRAM behind the cache after each flush, exactly like the CPU.

**How to think of it.** For every cache, list **every agent that can change the memory behind it** (here: the CPU, through a path the cache never sees). Each one needs a coherence answer: snooping, invalidation at a synchronization point, or an uncached path. Block-level specs written without the system's other agents in mind are a classic source of integration bugs.

**Other ways to catch it.** A full-chip test running two different kernels at the same code address; a coherence checklist reviewed at integration; a system assertion "no L2 hit on a line written by the CPU since the last flush".

## R10. Commands and fences through the write-back L2 (block 22)

**Symptom.** None in simulation: found while wiring the top level.

**Root cause.** The first block plan routed the CP ring fetch and the SQE fence writes through the crossbar and the L2, like every other memory access. But both are **shared with the CPU**: the CPU appends commands to the ring in DRAM while the GPU fetches them, and the CPU reads the fence from DRAM when the interrupt arrives. A ring line fetched while only half written would stay in the L2 and be returned again later with the old (empty) words; a fence write would sit dirty in the L2 and never reach DRAM before the interrupt.

**Fix.** The command fetch and the fences take an **uncached path** that joins the memory path below the L2 (a 4-way arbiter in front of the MMU). The crossbar now serves only the SMs.

**How to think of it.** Classify every memory stream by **who else reads or writes it**: private to the GPU (cache freely), produced by the CPU (fetch uncached or invalidate first), consumed by the CPU (write through or flush before signalling). Signalling memory (fences, doorbells, rings) is almost always uncached.

**Other ways to catch it.** A full-chip test that appends commands while the GPU is already running (the ring-wrap test does this); a CPU model that reads the fence the moment the interrupt fires, without any flush.

## General checklist: where RTL bugs hide

| Look at | Ask | Typical catch |
|---|---|---|
| Every valid/ready output | Is the payload frozen while waiting? Is valid independent of ready? | SVA hold property, formal |
| Every combinational arbiter | Can its choice change while a request is pending? | SVA hold property |
| Every same-cycle pair of events | Set and clear, launch and done, invalidate and request, write and read of the same entry: which wins, and is that the spec? | directed collision tests + coverage bins for "same cycle" |
| Every resource that is reused | What about responses still in flight for the previous owner? | stale bits, tags, drain checks |
| Every end-of-life event | Is anything still in flight? | hazard on EXIT / done, drain assertions |
| Every error or "do nothing" path | Does it keep the same protocol promises as the normal path? | SVA, formal, error-injection tests |
| Every block-to-block contract | Is each message visible to the block that needs it, for every corner value (0, max)? | integration tests, end-to-end assertions, cross-block coverage |
| Every growing structure | What bounds it, and can repetition break the bound? | max-depth coverage, directed loops |
| Every timing contract ("within N cycles") | Is the waiting side's window really at least N, and is N tested at its limit? | models that use the full allowed delay |
| Every cache and every shared buffer | Who else can write the memory behind it, or read what it holds? | coherence review at integration, CPU-writes tests |

## Appendix: testbench and methodology issues found

These were not RTL bugs, but each one would have hidden RTL bugs or reported false ones.

| Block | Issue | Lesson |
|---|---|---|
| all | Verilator parses covergroups but never counts bins: every run reported 0% | check that your coverage tool really counts; replaced by a bin counter |
| 01 | `[1:8] := 70` in a `dist` gives weight 70 to **each** value, so `0 := 5` almost never happened | `:=` is per value, `:/` is per range; coverage showed the zero bin at 0 hits |
| 03 | Verilator solves `dist` as a hard bucket choice, so `randomize() with` pinning a dist field fails | set directed fields directly, or disable the dist constraint |
| 03 | First WAIT_FOR_IDLE timing (busy within 2 cycles, settle 2) made the planted race bug undetectable | always confirm a planted bug can fail before trusting a pass; check the cycle arithmetic |
| 03 | Busy-storm test could never drain: background jobs kept starting | stop background stimulus before end-of-test drain checks |
| 04 | RAL model never `reset()`: mirror held 0 instead of reset values | call `reset()` after `build()`; the static-register test caught it |
| 04 | UVM bit-bash assumes silent RO writes; our RBBM returns SLVERR | library sequences encode assumptions; exclude or adapt per spec |
| 04 | Reference model forgot SOFT_RESET reads 0 | models are code too; mismatches can be the model's fault |
| 05 | SM model pulsed `wg_done` on the launch edge, losing it, and the test hung forever | stimulus must respect causality; add a global timeout so hangs fail fast |
| 05 | Coverage bin "launch into a slot the cycle its done arrives" was unreachable | unhit bins can be wrong bins; prove reachability before chasing them |
| 06 | Fetch sequences forked inside a fork branch, so `wait fork` did not wait for them | `wait fork` only waits for children of the current thread |
| 06 | Checker applied an invalidate to a miss that started in the same cycle | same-cycle ordering in the checker must match the spec, not convenience |
| 07 | End-of-test drain changed the config the program generator reads, changing the program under buffered instructions | never change what the reference depends on mid-run |
| 07 | Drain waited for warps to EXIT, but random programs can loop forever | design end-of-test so termination is guaranteed |
| 09 | Execution sink only unlocked registers if `ex_valid` was still high after the handshake: deadlock after 4 instructions | handshake bookkeeping must use the cycle of the handshake |
| 09 | Expected operand latency off by one | write the cycle-by-cycle timeline before coding a latency check |
| 06 | Planted `BUG_TAG_BITS` was missed: stimulus never toggled the top address bit | bug injection finds stimulus holes coverage did not ask about; toggle every address bit |
| 06 | Planted `BUG_FIXED_PRIO` can never fail: requesters with one request in flight cannot be starved | a missed planted bug is either a hole or an unneeded property: decide which |
| 15 | Random kernels let operations overwrite the argument-address register: stores to wild addresses, self-modifying code | generated programs need register conventions, like a compiler |
| 19 | `int x = expr;` inside `always_ff` is initialised once at time 0 | split declaration and assignment in static procedural blocks |
| 19 | Slave model dropped READY between the sampling edge and the clock edge | drive only just after the rising edge, sample at the falling edge |
| 20 | Read beats racing a write to the same word were compared | AXI defines no order there; exclude overlapping traffic from data checks |
| 09, 10 | `$sformatf("%s", c ? "abc" : "barrier")` with strings of different lengths gives wrong strings in Verilator: bins never counted | avoid ternaries between strings of different length; use `case` |
