# 02 CP ring fetch

## What this block is, in plain words

The CPU and the GPU share a circular list of commands in memory, the **ring buffer**. Think of a round table with numbered seats (dword slots). The CPU puts commands on seats and then moves a marker called **WPTR** (write pointer) to say "commands are ready up to here". The GPU has its own marker, **RPTR** (read pointer), that says "I have taken everything up to here". When the two markers are on the same seat there is nothing to do. After the last seat the numbering wraps back to seat 0.

The **ring fetch** is the GPU side of that table. Whenever WPTR is ahead of its own fetch position it reads the commands from memory, keeps them in a small queue (FIFO), and hands them one by one to the packet decoder (block 01). It also reports RPTR back so the CPU knows which seats it may reuse.

## Where it sits and who talks to it

```hflow
RBBM -WPTR-> Ring fetch -line read (valid/ready)-> Memory (crossbar, L2, DRAM)
Ring fetch -dwords (valid/ready)-> Packet decoder
Ring fetch -RPTR-> RBBM
```

| Who | Talks to | For what | Signals |
|---|---|---|---|
| RBBM (CPU registers) | ring fetch | ring start address, new WPTR | `ring_base[31:0]`, `wptr` |
| Ring fetch | memory system | read one 32-byte line of the ring | `mreq_valid`, `mreq_ready`, `mreq_addr[31:0]` |
| Memory system | ring fetch | the line contents, one 256-bit beat | `mrsp_valid`, `mrsp_data[255:0]` |
| Ring fetch | packet decoder | the next command dword | `dw_valid`, `dw_ready`, `dw_data[31:0]` |
| Ring fetch | RBBM / CPU | how far the GPU has consumed; whether it is busy | `rptr`, `busy` |

## The chip-wide memory port (first used here)

Every block in mGPU that reads memory uses the same simple port: **one request = one 32-byte line** (8 dwords), and **one response = one 256-bit beat**. Byte `4*i` of the line is dword `i`, carried in `mrsp_data[32*i +: 32]`.

Writers add three request fields: `mreq_we` (1 = write), `mreq_wdata[255:0]` (the line) and `mreq_wstrb[31:0]` (one enable bit per byte, so a single dword can be written). For a write, the response beat carries no data; it is the **acknowledgement** that the write has reached memory. The ring fetch only reads, so it does not have these wires; the SQE (block 03) is the first writer.

| Why one line per request | |
|---|---|
| A warp has 8 threads; 8 x 4 bytes = 32 bytes = one line. Caches, the crossbar and the L2 all move lines. | Using the same unit everywhere means no width converters inside the chip. Only GBIF (the AXI bridge) turns a line into an 8-beat AXI burst. |

## Architecture

```tree
cp_ring_fetch | fetch side + delivery side | root
  fptr | next ring dword to fetch from memory | comp
  rptr | next ring dword to hand to the decoder (reported to the CPU) | comp
  n_take logic | how many dwords this line request will keep | comp
  room check | the FIFO must have space for all of them before asking | comp
  Request FSM | IDLE, REQ, WAIT: one request in flight | comp
  FIFO (16 x 32) | multi-write (up to 8 per cycle), single read | comp
```

**How many dwords one request keeps.** Starting at `fptr`, the request keeps the smaller of: the dwords left to the end of the line (`8 - fptr[2:0]`), and the dwords the CPU has published (`wptr - fptr`). A request never keeps dwords from two lines, and never keeps dwords beyond WPTR.

```flow
box: IDLE | work exists (wptr != fptr) and FIFO room >= n_take?
arrow: yes: latch n_take and the line offset
box: REQ | mreq_valid = 1, address = ring_base + line of fptr | hw
arrow: mreq_ready
box: WAIT | on mrsp_valid: write n dwords into the FIFO, fptr += n | ok
back: back to IDLE
```

## RTL decisions and why

| Decision | Why |
|---|---|
| Two pointers: `fptr` (fetched) and `rptr` (delivered) | RPTR tells the CPU which seats are free. If we reported `fptr`, the CPU could overwrite seats whose commands are still sitting in our FIFO (not yet a problem for data, but it makes the "free space" meaning depend on FIFO depth). Reporting what was delivered is always safe. |
| Ring size is a power of two | Wrap-around is free: the pointers are `RING_LOG2` bits wide and simply overflow. `wptr - fptr` gives the right distance even after a wrap. |
| A request never crosses a line | A line is the unit of the memory port. Because the ring base is line aligned and the ring is at least 8 dwords, a line never crosses the ring end either. |
| Only one request in flight | Keeps the FIFO room check exact: nothing else can be landing in the FIFO while we decide. The cost is bandwidth (a bubble per line). The command stream is small compared with shader data, so this is acceptable. |
| Request only if the FIFO has room for **all** kept dwords | The memory response has no `ready`; it must be accepted the cycle it arrives. Reserving room before asking is what makes that safe. This is the planted bug `BUG_FIFO_ROOM`. |
| Partial lines are re-fetched | If WPTR stops in the middle of a line we take what is valid; when WPTR moves later we fetch the same line again for the rest. Simpler and always correct; the CPU usually publishes big batches. |
| `busy` = request in flight, or FIFO not empty, or `wptr != fptr` | Used by WAIT_FOR_IDLE and the hang detector: the block is idle only when everything published was fetched and delivered. |

## Waveform (from the simulation)

Smoke test, cycles 3 to 13 (column 0 of the figure is cycle 3). The CPU publishes 5 dwords (WPTR 0 to 5) then more. The fetcher asks for line 0, waits 5 cycles, keeps 5 dwords (fptr becomes 5), and starts delivering them. Because WPTR has moved on to 28, it immediately asks for line 0 again to get dwords 5 to 7.

```wave
clk        | ppppppppppp
wptr       | ===.....=..| 5 17 28 38
state      | ===....====| IDLE REQ WAIT IDLE REQ WAIT IDLE
mreq_valid | 01000000100
mrsp_valid | 00000010010
fptr       | =......=..=| 0 5 8
fifo count | =......====| 0 5 4 3 5
dw_valid   | 00000001111
rptr       | =.......===| 0 1 2 3
```

## RTL file

| File | What is inside |
|---|---|
| `rtl/02_cp_ring_fetch/cp_ring_fetch.sv` | pointers, request FSM, multi-write FIFO, planted bugs `BUG_LINE_CROSS` and `BUG_FIFO_ROOM` |

## Testbench architecture

This block is different from block 01: three of its four neighbours **react** to the DUT instead of being driven by a sequence. So the testbench has one sequence-driven agent (the CPU) and two reactive components (memory, decoder sink).

```hflow
Sequence -batches-> CPU driver -ring writes + WPTR-> DUT
DUT -line request-> Memory responder -line data-> DUT
DUT -dwords-> Sink (random ready)
```

```hflow
Monitor -published dwords-> Scoreboard
Monitor -line requests-> Scoreboard
Monitor -delivered dwords-> Scoreboard
```

| File | Plain-words role |
|---|---|
| `ring_fetch_interface.sv` | the wires |
| `ring_fetch_config.sv` | ring size (64 dwords in the testbench), knobs for sink readiness, memory latency and request readiness; `ring_memory`, the shared memory model |
| `ring_fetch_transactions.sv` | `ring_cmd` (a batch of new commands), `ring_wptr_item` (WPTR moved, with the new dwords), `ring_req_item` (one line request and its latency), `ring_dw_item` (one delivered dword) |
| `ring_fetch_sequences.sv` | `ring_rand_seq` (random batch sizes and gaps), `ring_full_seq` (fill the ring to its limit, six times) |
| `ring_fetch_cpu_driver.sv` | plays the CPU software: writes dwords into the memory model, then moves WPTR, never filling the last free seat |
| `ring_fetch_memory_responder.sv` | plays the memory: random `mreq_ready`, random latency, answers from the memory model |
| `ring_fetch_sink.sv` | plays the decoder: random `dw_ready` |
| `ring_fetch_monitor.sv` | turns pins into the three transaction kinds |
| `ring_fetch_scoreboard.sv` | data order, RPTR value and request legality checks |
| `ring_fetch_coverage.sv` | 17 bins: transaction bins plus cycle bins from internal probe wires |
| `ring_fetch_assertions.sv` | 8 SVA properties |
| `ring_fetch_env.sv`, `ring_fetch_tests.sv`, `ring_fetch_pkg.sv`, `ring_fetch_tb_top.sv`, `Makefile` | wiring, six tests, package, top with the text waveform |

## Verification decisions and why

**What we check, in one sentence.** The decoder receives exactly the dwords the CPU published, in order, with none lost, repeated or invented; RPTR is always honest; every memory request is legal and useful; and the block always drains to idle.

| Decision | Why |
|---|---|
| The CPU agent obeys the "one seat stays free" rule | That is the software contract: `wptr == rptr` means empty, so a full ring must stop one short. Breaking it is a software bug, not a GPU bug, so the testbench must not do it. The `full_ring` test pushes exactly to that limit. |
| Expected data comes from the monitor reading the memory model **when WPTR moves** | That is the moment the data becomes "published". It checks the DUT against what was really in memory at that time, independent of how the sequence chose the data. |
| Responder latency and request readiness are random and separate | Two different stalls: memory not accepting the request, and memory slow to answer. Each exercises a different FSM state (REQ vs WAIT). |
| Scoreboard checks RPTR on every delivered dword | RPTR is what software uses to reuse seats. A wrong RPTR (even off by one) lets the CPU overwrite commands the GPU has not read yet, a data-corruption bug visible only much later. |
| Request legality: aligned, inside the ring, holds unfetched work | A request outside the ring reads someone else's memory (a security bug). A request with no useful dword is a wasted memory trip (a performance bug). |
| Drain check at the end with a timeout | A hang (WPTR ahead, nothing happening) would otherwise end the test quietly. The test fails if the block does not go idle with `wptr == rptr`. |
| Small ring (64 dwords) in the testbench | The RTL is parameterized. A small ring wraps hundreds of times per test, so the wrap logic is exercised constantly. |
| Coverage reads internal probes (`dut.count`, `dut.room`) | "The FIFO was full" and "a fetch was blocked by room" are invisible on the pins, but they are exactly the conditions the room check exists for. White-box coverage proves we reached them. |

**Why these coverage bins.**

| Bins | Why |
|---|---|
| batch sizes 1, 2-7, 8, 9-31, near full | single-dword publishes stress partial lines; near-full stresses the free-seat rule |
| wptr wrap, wptr moved during a request | wrap math; and new work arriving while a fetch is in flight must not confuse `n_take` |
| latency short / mid / long | the FSM waiting different times in WAIT |
| first line, last line requested | the two ends of the ring, where wrap bugs appear |
| out_stall, fifo_full, fetch_blocked_by_room | backpressure all the way from the decoder to the fetch decision |
| ring full with one free seat, idle and empty | the two extremes of the ring state |

**Why these assertions.**

| Assertion | Rule | Why |
|---|---|---|
| `a_req_stable` | a request stays valid with the same address until accepted | valid/ready rule; a changing address would fetch the wrong line |
| `a_req_aligned` | request address is line aligned | memory port rule |
| `a_one_outstanding` | never a second request in flight | the room reservation depends on it |
| `a_fifo_bound` | FIFO count never above 16 | overflow overwrites commands. This assertion caught `BUG_FIFO_ROOM` in the very cycle it happened, before the scoreboard saw bad data |
| `a_out_stable` | a stalled output dword does not change | valid/ready rule toward the decoder |
| `a_rptr_only_on_pop` | RPTR moves only when a dword is delivered | RPTR honesty, cycle by cycle |
| `a_idle_means_empty` | not busy implies nothing left | WAIT_FOR_IDLE must never finish early |
| `a_no_x` | no X on control outputs | |

## Tests and why each exists

| Test | Knobs | Purpose |
|---|---|---|
| `ring_fetch_smoke_test` | 20 batches, fast everything | bring-up |
| `ring_fetch_rand_test` | 300 batches, sink 70%, latency 0-6, request ready 70% | general random |
| `ring_fetch_slow_sink_test` | sink 15% | FIFO fills; fetch must wait for room |
| `ring_fetch_slow_mem_test` | latency 5-20, request ready 40% | long WAIT and REQ states; WPTR moves during requests |
| `ring_fetch_full_ring_test` | 6 batches of 63 dwords | ring at its limit; the CPU waits for RPTR |
| `ring_fetch_wrap_stress_test` | 500 batches of 1-3 dwords, no gaps | many partial lines, many wraps |

## Results

| Item | Result |
|---|---|
| Regression | 6 tests x 3 seeds = 18 runs, all PASS |
| Dwords checked | 175 to 2,241 per run, 0 mismatches |
| Merged functional coverage | 100% (17 of 17 bins) |
| `BUG_LINE_CROSS` (take 8 dwords even from the middle of a line) | **caught** by the scoreboard: `dword #9: expected 0e12fce8, got c61f8eb3` (it re-delivered old data) |
| `BUG_FIFO_ROOM` (room check one short) | **caught** first by `a_fifo_bound` ("FIFO count above depth") and `a_out_stable`, then by the scoreboard |

## What is not verified here

- A reset or a new `ring_base` while commands are in flight (handled by the CP-level reset sequence later).
- Memory errors on the response (the memory port has no error signal yet; it is added with the MMU, block 18).

# Teaching section: the ring fetch in context

## The block and its pins

```pins
block: Ring fetch | cp_ring_fetch.sv · 1024-dword ring · 16-dword FIFO · 1 request outstanding
in: ring_base, wptr | rbbm | where the ring lives in memory, and how far the CPU has written
in: mrsp_valid, mrsp_data[255:0] | below-L2 arbiter (MMU, GBIF, DRAM) | the 32-byte line that was asked for
in: mreq_ready | below-L2 arbiter | memory path can take the request
out: rptr | rbbm (RING_RPTR) | how many dwords have been handed to the decoder
out: mreq_valid, mreq_addr | below-L2 arbiter | read one 32-byte line of the ring (uncached)
out: dw_valid / dw_ready, dw_data | cp_packet_decoder | one command dword from the FIFO
out: busy | top busy bit 3 | a request in flight, dwords in the FIFO, or wptr not yet reached
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the command processor

```hflow
CPU | writes ring, then WPTR -APB-> RBBM | ring_base, wptr -wptr-> Ring fetch | reads lines | you -dwords-> Packet decoder | splits packets -ops-> SQE | executes
```

The ring fetch is the **first stage of the command processor**. It is the only part of the CP that reads memory for commands. It turns "the CPU says there is work up to `wptr`" into a steady stream of dwords. Its memory requests go to the arbiter below the L2, so they skip the caches entirely:

| Path | Who uses it | Why |
|---|---|---|
| Through L1 and L2 | SM loads and stores | data is reused, caching pays off |
| Below the L2 (uncached) | ring fetch, SQE fences | the CPU writes the ring directly in DRAM; a cached copy could be stale |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| RBBM (04) | ring_base, wptr in; rptr out | The CPU programs RING_BASE and RING_WPTR over APB; it reads RING_RPTR to see how far the GPU has consumed, so it knows which ring space it may reuse. |
| Below-L2 arbiter in mgpu_top | mreq_*, mrsp_* | One of four requesters (two L2 banks, ring fetch, SQE). The request goes through the MMU and the GBIF to DRAM, and the 256-bit line comes back. |
| Packet decoder (01) | dw_* out | Pulls dwords one per cycle when it can. |
| Busy and progress logic in mgpu_top | busy, dw handshake | Busy bit 3 is `rf_busy || dec_busy`; each accepted dword is "progress" for the hang detector and a perf event. |

## Design details

- **Three pointers.** `wptr` (from the CPU) says where valid commands end. `fptr` (internal) says which dword to fetch next. `rptr` (output) counts dwords actually handed to the decoder. `avail = wptr - fptr` is the number of dwords still to fetch. All are dword indexes of `RING_LOG2 = 10` bits, so they wrap naturally at 1024: the ring is circular with no extra wrap logic.
- **Line-based requests.** Each request reads one aligned 32-byte line (8 dwords). If `fptr` is in the middle of a line, only the dwords from `fptr` to the end of the line are kept (`to_line_end`), and fewer if `wptr` comes first (`n_take`). The FIFO write uses `off_q` to pick the right dwords out of the 256-bit beat.
- **Ask only if there is room.** The FSM leaves `S_IDLE` only if the FIFO has space for every dword it will keep (`room`). So a response can always be written in full; there is no need to drop data or to stall the memory response.
- **One outstanding request.** `S_IDLE -> S_REQ -> S_WAIT -> S_IDLE`. Simple and in order, but the memory latency is exposed for every line. For a command stream this is acceptable, because one DISPATCH packet starts a lot of compute.
- **Partial lines are re-read.** If the CPU has only written part of a line, the fetch takes what is valid and later reads the same line again for the rest. It never reads past `wptr`, so it never executes half-written commands.
- **Busy is conservative.** `busy` stays high while `wptr != fptr`, so even a moment before the next request is issued, the CP reports itself busy. That is what WAIT_FOR_IDLE and the hang detector need.

## Questions: what if we did it differently?

**Q1. What if the CPU pushed commands through MMIO (doorbell writes of each dword) instead of a DMA ring?**
Then the RBBM would need a command FIFO, and every dword would cost an APB write from the CPU. No ring fetch would be needed, but the CPU would be slow and busy feeding the GPU. With the ring, the CPU writes plain memory at full speed and rings a *doorbell* once (the WPTR write). The testbench would replace "write DRAM, then WPTR" with a stream of APB writes and check FIFO-full backpressure (`pready` low or an error).

**Q2. What if we allowed several outstanding requests?**
The fetch could hide memory latency by having two or three lines in flight. It needs request tags (or an in-order guarantee from the memory path), FIFO room reserved per request, and a pointer per request. Throughput rises; logic and verification effort rise. The testbench's memory model would need to return responses with varying latency, possibly out of order, and the scoreboard would still expect the dwords in order.

**Q3. What if commands went through the L2 cache?**
Repeated command buffers (an "indirect buffer" called many times) would hit in the cache. But the CPU writes the ring in DRAM, and our L2 is not coherent with the CPU, so the GPU could read stale commands. You would need either a cache flush before each WPTR update or a coherent (snooping) path. That is exactly why the design keeps commands uncached.

**Q4. What if the GPU polled a WPTR copy in memory instead of the CPU writing a register?**
That is *memory-based doorbell polling*. The CPU never touches GPU registers, which suits virtualization, but the GPU wastes memory bandwidth polling and reacts later. Real GPUs often combine both: a doorbell write wakes the engine, and the pointer itself lives in memory. The testbench would need a memory-resident WPTR and a timing check that the fetch eventually notices updates.

**Q5. What if the ring were bigger, or the FIFO deeper?**
`RING_LOG2` is a parameter: a bigger ring lets the CPU queue more work before waiting for `rptr`. A deeper FIFO lets the fetch run further ahead of a stalled decoder, but with one request outstanding, depth beyond a couple of lines mostly adds area. The testbench should then test wraparound at the new size, and FIFO-full with the new depth.

**Q6. What breaks with `BUG_LINE_CROSS`?**
`n_take` takes up to 8 dwords without checking the line end. When `fptr` is not line-aligned, the fetch keeps 8 dwords but only `to_line_end` of them really belong to this line; the rest come from beyond the 256-bit beat, so garbage dwords enter the FIFO and `fptr` skips ahead. The symptom appears after any partial line, for example after the CPU publishes a WPTR that is not a multiple of 8. A test with odd WPTR steps catches it.

**Q7. What breaks with `BUG_FIFO_ROOM`?**
The room check is off by one, so a request can be issued when the FIFO is one dword short. The response then overwrites the oldest unread dword (the FIFO wraps), and `count` exceeds the depth. The symptom is a lost or duplicated command dword, only when the decoder is stalled and the FIFO is nearly full. A test must apply long backpressure on `dw_ready` to see it.

**Q8. What if we used a credit-based interface to the decoder instead of valid/ready?**
With credits the decoder would grant the fetch a number of slots up front, and the fetch would send without waiting for `ready`. That helps when there is wire delay between the two blocks. Here they sit side by side, so valid/ready is simpler. A credit scheme would need credit counters on both sides and a testbench check that credits are never exceeded.

**Q9. What if the ring held 64-bit pointers to indirect buffers?**
Real CPs support *indirect buffers*: a ring packet points to another command buffer elsewhere in memory, and the fetch switches to it, then returns. This needs a second set of pointers (a small stack) and a new packet type. It lets a driver reuse a prebuilt command list many times. The testbench would need a nested memory layout and checks that the fetch returns to the ring in the right place.
