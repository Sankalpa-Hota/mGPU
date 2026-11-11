# 20 DRAM controller

## What this block is, in plain words

The DRAM controller is the AXI4 slave in front of the actual memory (1 MB in the simulation). It stores and returns data and models the most important timing effect of real DRAM: memory is organized in **rows**, and each bank keeps one row **open**. An access to the open row is fast (2 cycles); another row needs closing and opening first (8 cycles).

## Behaviour

| Request | Answer |
|---|---|
| INCR burst, 1 to 16 beats of 4 bytes, inside memory | OKAY; data / strobed writes |
| FIXED or WRAP burst, or a size other than 4 bytes | SLVERR, memory untouched |
| any byte beyond the memory size | DECERR, never wraps onto real memory |

Reads and writes have separate state machines; when both want to start in the same cycle they alternate.

## RTL decisions and why

| Decision | Why |
|---|---|
| Row-buffer model: 4 banks (address bits 11:10), open row per bank, hit 2 / miss 8 cycles | Teaches why access patterns matter, and gives the full-chip test real latency variation. |
| DECERR for out-of-range addresses | A stray address must never alias onto real data (`BUG_NO_DECERR`). |
| Each read beat captured in a register when offered | RDATA must not change while RREADY is low; the first version read the array combinationally and a concurrent write to the same word changed the offered beat (issue log R8, `BUG_RDATA_LIVE`). |
| Strobes applied per byte | Partial writes (`BUG_WSTRB_IGNORE`). |

## Verification decisions and why

| Decision | Why |
|---|---|
| AXI master with concurrent read and write streams | Real traffic overlaps; this is what exposed issue R8. |
| Byte-level golden memory; reads compared per beat | Exact data check. |
| A read beat that overlaps a write in flight (at any time during the read burst) is not compared | AXI defines no order between them; checking it would report false errors. |
| Row model in the checker predicts hit / miss for every burst | Verifies the timing model, not only the data. |
| The master's own bursts are checked by the same AXI checker | It caught the testbench breaking the 4 KB rule with out-of-range addresses. |

## Results

| Item | Result |
|---|---|
| Regression | 4 tests x 3 seeds = 12 runs, all PASS (4,000 bursts per random run) |
| Merged coverage | 100% (15 of 15) |
| `BUG_WSTRB_IGNORE`, `BUG_RLAST_EARLY`, `BUG_NO_DECERR`, `BUG_RDATA_LIVE` | all 4 caught |

# Teaching section: the DRAM controller in context

## The block and its pins

```pins
block: DRAM controller | dram_ctrl.sv · AXI4 slave · 32-bit data · 2^MW bytes (1 MB in mgpu_system) · 4 banks, open-row timing model
in: araddr, arlen, arsize, arburst, arvalid / arready | GBIF (AR channel) | read burst request
in: awaddr, awlen, awsize, awburst, awvalid / awready | GBIF (AW channel) | write burst request
in: wdata, wstrb, wlast, wvalid / wready | GBIF (W channel) | write data beats with byte strobes
in: rready | GBIF (R channel) | master can take a read beat
in: bready | GBIF (B channel) | master can take the write response
out: rdata, rresp, rlast, rvalid | GBIF (R channel) | read beats, held stable until accepted
out: bresp, bvalid | GBIF (B channel) | write response: OKAY, SLVERR or DECERR
out: stat_row_hit, stat_row_miss | mgpu_top dram_perf[1:0] | one-cycle pulses when a burst starts on an open row or not
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the memory path

```hflow
MMU | physical line -line req-> GBIF | line to AXI burst -AXI4-> DRAM controller | timing + array | you -row hit/miss-> RBBM perf counters | count events
```

The DRAM controller is **outside the GPU**: `mgpu_system` puts it next to `mgpu_top` to make a complete system. It is both the memory (a plain array `mem`) and a simple timing model of a DRAM device with banks and rows.

| Address bits (MW = 20) | Meaning |
|---|---|
| 1-0 | byte within a 32-bit word |
| 11-10 | bank (4 banks) |
| 19-12 | row inside the bank |

| Burst check | Response |
|---|---|
| INCR, size 4 bytes, 1 to 16 beats, fully inside memory | OKAY |
| FIXED or WRAP, other size, or more than 16 beats | SLVERR, memory untouched |
| start or end beyond 2^MW bytes | DECERR, never wraps onto real memory |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| GBIF (19) via mgpu_top AXI ports | all five AXI channels | The only master. Every line refill, writeback, page-walk read, ring fetch and fence write ends here. |
| mgpu_top `dram_perf` | stat_row_hit, stat_row_miss | In `mgpu_system` wired as `{14'd0, row_miss, row_hit}`; becomes two RBBM performance events. |
| Testbench / CPU model | backdoor to `mem` | Loads programs, data and page tables and reads results (the CPU's view of DRAM). |

## Design details

- **Two independent sides.** A read FSM (R_IDLE, R_WAIT, R_DATA) and a write FSM (W_IDLE, W_WAIT, W_DATA, W_RESP) run in parallel. So one read and one write can be in progress at the same time.
- **Start arbitration.** If both a read and a write want to start in the same cycle, they alternate using `last_was_read`. This is a tiny fairness rule so a stream of reads cannot starve writes or the reverse.
- **Open-row model.** Each of the 4 banks remembers one open row (`open_row`, `row_ok`). A burst to the open row waits `T_HIT` cycles (2 in the system); any other row waits `T_MISS` cycles (8), standing in for precharge plus activate. The row is then left open: this is an *open-page policy*.
- **Latency counted per burst, not per beat.** After the wait, beats flow one per cycle while the master is ready. A real DRAM also has column timing, but per-burst latency keeps the model easy to reason about.
- **Read data is registered.** Each beat is put into `rdata_q` when offered and only advances on `rready`, so RDATA is stable while RVALID is high and RREADY is low, as AXI requires.
- **Write strobes.** Each byte lane is written only if its `wstrb` bit is set, so partial writes (fences, partial lines) work.
- **Errors are full bursts.** Even an SLVERR/DECERR read returns all its beats (zero data) with RLAST at the end, and a bad write still takes all its W beats before BRESP. AXI requires the full burst to complete even on error.

## Questions: what if we did it differently?

**Q1. Open-page versus closed-page policy?**
We leave the row open after every burst (open-page). That wins when the next access goes to the same row (streams, a sweep over an array): `T_HIT` instead of `T_MISS`. Closed-page precharges right after each access, so every access pays the activate cost but never pays a precharge on a miss. Random traffic favours closed-page. Hardware change: the latency function would ignore `open_row` and return a single middle value. The perf counters would show no row hits at all. Many controllers use an adaptive policy with a timer that closes an idle row.

**Q2. FCFS versus FR-FCFS scheduling?**
We take requests strictly in arrival order (one read, one write at a time). *FR-FCFS* (first-ready, first-come-first-served) keeps a queue and prefers requests that hit an open row, reordering to raise row-hit rate. It needs a request queue, a row-hit comparator per entry, starvation protection (age caps), and AXI IDs so out-of-order responses are allowed. The bench would need multiple outstanding IDs and order-independent checking.

**Q3. What about refresh?**
Real DRAM cells leak and must be refreshed every few microseconds. Our array never forgets, so there is no refresh. Adding it means a refresh timer that periodically blocks new bursts, closes all rows (`row_ok` cleared) and inserts a refresh delay. Bandwidth drops a few percent and latency gets occasional spikes. Tests would need to check that a burst arriving during refresh is delayed but still correct.

**Q4. Bank interleaving: why bank = bits 11-10?**
With bank bits just above the 1 KB row-column region, consecutive 1 KB blocks fall in different banks, so a long stream spreads across banks. Alternatives: put bank bits lower (spreads small strides more but splits a page's lines), or XOR-hash bank bits with row bits (permutation-based interleaving) to break up pathological strides that keep hitting one bank. Our model only uses banks for open-row tracking; a real one would also overlap activates in different banks.

**Q5. Why one read and one write pending instead of a deep queue?**
Simplicity and a clean AXI model. A deeper design would accept many AR/AW requests, track them with IDs, and return in any order across IDs. Our only master (GBIF) issues one transaction at a time anyway, so a queue would not help until the GBIF is upgraded too.

**Q6. Why SLVERR for WRAP and FIXED instead of supporting them?**
Supporting WRAP needs an address that wraps at the burst-size boundary; FIXED needs the address to stay constant (FIFO-like targets). Neither is needed by the GBIF, so rejecting them with SLVERR keeps the controller small but still protocol-correct: an error is a legal answer, silently doing the wrong thing is not.

**Q7. What do `BUG_NO_DECERR` and `BUG_WSTRB_IGNORE` break?**
`BUG_NO_DECERR` drops the out-of-range check, so an address beyond 1 MB is indexed with only its low MW bits and silently aliases onto real memory: reads return other data and writes corrupt it, with OKAY. `BUG_WSTRB_IGNORE` writes all four bytes of every beat, so a partial write (the fence write, a masked store line) destroys neighbouring bytes with whatever is in the data bus.

**Q8. What do `BUG_RDATA_LIVE` and `BUG_RLAST_EARLY` break?**
`BUG_RDATA_LIVE` drives `rdata` directly from the array instead of a held register. If the master stalls (RREADY low) while a write changes that word, RDATA changes under a valid beat, which AXI forbids; the bench needs random RREADY back-pressure plus concurrent writes to see it. `BUG_RLAST_EARLY` raises RLAST on both of the last two beats, so the master thinks the burst ended one beat early; an AXI checker catches the mismatch with ARLEN immediately.
