# 16 Crossbar

## What this block is, in plain words

The SMs share an L2 cache that is split into two **banks** so two requests can be served at once. The crossbar connects every requester to every bank: it sends each request to the bank that owns its address and sends each answer back to whoever asked. Consecutive lines alternate between banks (line address bit 5), which spreads traffic evenly.

## RTL decisions and why

| Decision | Why |
|---|---|
| Bank = address bit 5 | Interleaving by line spreads sequential access over both banks (`BUG_BANK_BIT` uses bit 6: both banks still work, but each receives addresses that are not its own). |
| Round-robin per bank, choice held while the bank is not ready | Fairness and the valid/ready rule (`BUG_NO_HOLD`). |
| Requests carry the requester id; answers return by id | A bank may hold several requests and answer them in any order; returning to "whoever was granted last" is wrong as soon as two are in flight (`BUG_RSP_ROUTE`). |
| Parameterized: 4 requesters in its own bench, 2 (the SMs) in the chip | In the final chip the command fetch and the fences take the uncached path (see block 22). |

## Verification decisions and why

| Decision | Why |
|---|---|
| Bank models accept up to 4 requests and answer **out of order** | The only way to make id routing matter. |
| Answers carry a value that identifies their request (write: the data; read: a function of the address) | The checker can tell whether a requester got *its own* answer. |
| Fairness check: a requester never loses the same bank more than 3 times in a row | 4 requesters, round-robin: anything more is starvation. |
| Hot-bank test: 90% of requests to one bank, always requesting | Maximum contention. |

## Results

| Item | Result |
|---|---|
| Regression | 4 tests x 3 seeds = 12 runs, all PASS (15,425 answers in one random run) |
| Merged coverage | 100% (14 of 14), including out-of-order answers |
| `BUG_BANK_BIT`, `BUG_NO_HOLD`, `BUG_RSP_ROUTE` | all caught |

# Teaching section: the crossbar in context

## The block and its pins

```pins
block: Crossbar | crossbar.sv · N=2 SMs x NB=2 L2 banks (mgpu_top) · per-bank round-robin · ids on answers
in: req_valid[N] / req_ready[N] | SM memory ports | handshake per SM: a line request offered / accepted by its bank
in: req_addr, req_we, req_wdata, req_wstrb [N] | SM memory ports | line address, read or write, data and strobes
in: b_ready[NB] | L2 banks | bank is idle and accepts a request
in: b_rsp_valid, b_rsp_data, b_rsp_id [NB] | L2 banks | an answer and the requester id it belongs to
out: rsp_valid[N], rsp_data[N] | SM memory ports | answer routed back to the SM that asked
out: b_valid[NB], b_addr, b_we, b_wdata, b_wstrb, b_id [NB] | L2 banks | the selected request for each bank, tagged with the requester id
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the memory path

```hflow
SM 0 and SM 1 | L1 and I-cache traffic -line req-> Crossbar | route by bank bit | you -bank req + id-> L2 bank 0 / 1 | one request at a time -miss-> Below-L2 arbiter | then MMU and DRAM
```

The bank is chosen by line-address bit 5 (with 2 banks), so line 0 goes to bank 0, line 1 to bank 1, line 2 to bank 0, and so on. Consecutive lines alternate banks, so a streaming kernel spreads its traffic evenly.

| Situation | What happens |
|---|---|
| SM0 to bank 0, SM1 to bank 1 | both requests pass in the same cycle |
| Both SMs to the same bank | round-robin picks one; the other keeps its valid high and waits |
| Answers | each bank returns the id; the crossbar raises `rsp_valid` only on that SM |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| SM 0 and SM 1 (15) | req_* in, rsp_* out | Each SM has one memory port and at most one outstanding request. |
| L2 banks (17) | b_* out, b_rsp_* in | `b_id` becomes the bank's `req_id`; the bank echoes it as `rsp_id`. |
| mgpu_top (22) | instantiation | `crossbar #(.N(2), .NB(2)) u_xbar`, ids are 1 bit wide. |

## Design details

- **Bank selection** is a pure function `bank_of(addr) = addr >> 5` truncated to the bank bits. No table, no hashing: the lowest line-address bits pick the bank.
- **One arbiter per bank.** For each bank the crossbar scans requesters starting at `rr[b]` and picks the first one whose address maps there. After a grant `rr[b]` moves to the requester after the winner, so nobody can starve.
- **Hold rule.** If a bank was offered a request and did not accept it (`b_valid && !b_ready`), `held` keeps the same requester selected next cycle. This keeps valid and payload stable until accepted, as the valid/ready protocol requires.
- **Ids instead of order.** Banks may answer in a different order than requests were granted across banks, so each request carries the requester index and the answer is steered by that index. The crossbar itself keeps no per-request state for answers.
- **Purely combinational paths.** Requests and answers pass without a register, so the crossbar adds no latency; the only flops are `rr`, `held` and `held_id`.
- **Why it is simple.** Each SM has at most one request in flight (its line arbiter enforces this), so the crossbar never has to buffer or reorder data.

## Questions: what if we did it differently?

**Q1. What if we used a ring or a mesh network-on-chip instead of a crossbar?**
A crossbar is N x NB muxes: cheap for 2 x 2 but its wiring grows with N x NB. A *ring* connects nodes in a loop with routers, so wiring grows linearly but latency grows with distance and the ring is shared bandwidth. A *mesh* with routers (XY routing, virtual channels) scales to many SMs but needs buffers, flow control (credits) and deadlock avoidance. Testbench: packet-level scoreboards with variable latency, and checks for ordering per source-destination pair.

**Q2. What if arbitration were fixed-priority, or iSLIP?**
*Fixed priority* (SM0 always wins) is the smallest logic, but SM1 can starve under heavy SM0 traffic. *Round-robin* (ours) guarantees fairness per bank. *iSLIP* is a matching algorithm for input-queued switches with several outstanding requests per input (virtual output queues): it iterates request/grant/accept to maximize simultaneous matches. With one request per SM, round-robin already achieves the best match, so iSLIP would add cost without benefit. Testbench: a fairness check (bounded wait) would fail for fixed priority.

**Q3. What if bank selection used address hashing instead of bit 5?**
With plain low bits, a stride of 64 bytes (2 lines) always hits the same bank. *XOR hashing* (bank = bit5 ^ bit10 ^ ...) spreads such strides. The L2 bank must then rebuild the full line address differently, since in l2_cache.sv `addr_of` inserts its own bank number at bits [5 +: BW]; with hashing the bank bits would have to be stored in the tag. Testbench: the reference `bank_of` function must match.

**Q4. What if each SM could have several requests outstanding?**
Then two answers for the same SM could arrive in the same cycle from two banks and the SM would need to accept both or the crossbar would need answer buffering and an answer arbiter. Ids would grow to include a transaction tag, not just the SM index. Testbench: out-of-order answer matching per tag.

**Q5. What happens with `BUG_BANK_BIT`?**
`bank_of` uses bit 6 instead of bit 5. Requests still reach a bank, but the wrong one for half the lines. Since each L2 bank rebuilds addresses with its own bank number, write-backs and fills go to wrong DRAM addresses and data is corrupted or read from the wrong place. The crossbar test checks that each request appears on the expected bank.

**Q6. What happens with `BUG_NO_HOLD`?**
A request that was offered but not accepted is not held; if another requester becomes valid with higher round-robin priority, the bank sees the valid's payload change while valid is high. This breaks the rule "once valid, payload stays stable until ready". Real slaves that sample over several cycles would mix two requests. A protocol assertion (`b_valid && !b_ready |=> $stable(b_addr)`) catches it.

**Q7. What happens with `BUG_RSP_ROUTE`?**
Answers go to `last_grant[b]` (whoever the bank last accepted) instead of `b_rsp_id`. While each bank serves one request at a time this often looks right, but if the bank accepted a new requester before answering an older one, the answer goes to the wrong SM: one SM gets someone else's data and the other hangs waiting. The test with out-of-order bank answers exposes it.

**Q8. Why not put buffers (FIFOs) in the crossbar?**
Input or output queues decouple the SMs from bank stalls and let the crossbar absorb bursts. They cost flops (each entry is about 300 bits wide here) and add a cycle of latency. With single-outstanding requesters there is nothing to buffer, so the design stays combinational.
