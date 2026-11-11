# 01 CP packet decoder

## What this block is, in plain words

The CPU talks to the GPU by writing **packets** into a ring buffer in memory. The command processor (CP) reads that ring one 32-bit word (a *dword*) at a time. The **packet decoder** is the part of the CP that understands the words. It looks at the first word of each packet (the header) and decides:

- "this is a **type 4** packet: the next N words are values for N consecutive registers", so it sends each word out as a register write with the right address, or
- "this is a **type 7** packet: the next N words belong to operation OP", so it forwards each word to the SQE (the CP's small sequencer that runs operations such as DISPATCH), or
- "this header is nonsense", so it raises an error flag and keeps going.

It is the front door of the GPU. If it gets one count wrong, every packet after that is misread, and the GPU writes garbage into its own configuration.

## Where it sits and who talks to it

```hflow
Ring fetch -dwords (valid/ready)-> Packet decoder -register writes-> Register bus
Packet decoder -opcode dwords-> SQE
```

| Who | Talks to | For what | Signals |
|---|---|---|---|
| CP ring fetch | packet decoder | the next command dword | `dw_valid`, `dw_ready`, `dw_data[31:0]` |
| Register bus / SQE | packet decoder | "I can take a payload word this cycle" | `out_ready` |
| Packet decoder | register bus | write register `reg_wr_addr` with `reg_wr_data` | `reg_wr_en`, `reg_wr_addr[17:0]`, `reg_wr_data[31:0]` |
| Packet decoder | SQE | one payload word of operation `op_code` | `op_valid`, `op_code[6:0]`, `op_data[31:0]`, `op_last` |
| Packet decoder | RBBM | error status and busy status | `bad_pkt` (sticky), `busy` |

## Packet formats it understands

| Field | Type 4 (register write) | Type 7 (operation) |
|---|---|---|
| `[31:28]` | 4 | 7 |
| address / opcode | `[25:8]` first register (18 bits) | `[22:16]` opcode (7 bits) |
| count | `[6:0]` number of registers (0 to 127) | `[13:0]` number of payload dwords (0 to 16383) |

Example: `0x40010002` is type 4, first register `0x00100`, count 2. The next two dwords go to registers `0x00100` and `0x00101`.

## Architecture

```tree
cp_packet_decoder | header parse + payload routing | root
  State register | S_HDR (waiting for a header), S_T4, S_T7 | comp
  remain counter | payload dwords still to come in this packet | comp
  cur_reg | next register address, +1 after every type 4 payload word | comp
  cur_op | opcode latched from the type 7 header | comp
  bad_pkt flag | set by an illegal header, cleared only by reset | comp
  Output routing | combinational: payload word goes to reg bus or SQE | comp
```

```flow
box: S_HDR | wait for a header; dw_ready is always 1 here
arrow: type 4 header, count > 0
box: S_T4 | each accepted word = register write to cur_reg; cur_reg + 1; remain - 1 | hw
arrow: remain reaches 0
back: back to S_HDR (count 0 headers never leave S_HDR; type 7 goes to S_T7 the same way)
```

## RTL decisions and why

| Decision | Why |
|---|---|
| Headers are always accepted (`dw_ready = 1` in S_HDR) | A header produces no output, so there is nothing downstream to wait for. Stalling here would waste a cycle per packet for no reason. |
| Payload words wait for `out_ready` (`dw_ready = out_ready` in S_T4/S_T7) | The register bus or SQE may be busy. Backpressure must flow back to the ring fetch; dropping a word would shift every later packet. |
| Outputs are combinational from the accepted input | Zero added latency: the register write happens in the same cycle the word is accepted. The cost is a longer combinational path, acceptable at this size. |
| A count of 0 returns to S_HDR immediately | A zero-length packet is legal and must not swallow the next header. This is a classic bug, planted as `BUG_ZERO_COUNT`. |
| `cur_reg` is 18 bits and wraps from `0x3FFFF` to `0x00000` | That is the natural width of the register space; the wrap is defined behavior and the testbench checks it. |
| An illegal header is consumed as one dword and `bad_pkt` is set (sticky) | The decoder cannot know how long a broken packet is, so it skips one word and tries the next as a header. The sticky flag makes sure software sees the error even if it reads the status much later. |
| `op_last` marks the final payload word of a type 7 | The SQE knows when it has all operands without counting itself. |
| `busy` = not in S_HDR | Feeds WAIT_FOR_IDLE and the hang detector in RBBM. |

## Waveform (from the simulation)

Directed test, first cycles after reset. `H4` = type 4 header (count 1), `D` = its data, `Z4` = type 4 with count 0, `Z7` = type 7 with count 0, `H7` = type 7 header with count 2, `P0`/`P1` = its payload.

```wave
clk       | ppppppppp
dw_valid  | 011111111
dw_data   | x========| H4 D Z4 Z7 H7 P0 P1 H4
reg_wr_en | 001000000
op_valid  | 000000110
op_last   | 000000010
busy      | 001000110
```

Under backpressure (backpressure test), the word `0ba1fe12` is offered at cycle 14, `out_ready` stays low for 6 cycles, and the register write happens only at cycle 20, the first cycle with `out_ready = 1`. `dw_data` does not change while waiting.

## RTL file

| File | What is inside |
|---|---|
| `rtl/01_cp_packet_decoder/cp_packet_decoder.sv` | the decoder: state machine, counters, routing, and two planted bugs (`BUG_T4_NOINC`, `BUG_ZERO_COUNT`) |

## Testbench architecture

```hflow
Sequences -packets-> Driver -dword stream + out_ready-> DUT
```

```hflow
Monitor -accepted dwords-> Reference model -expected outputs-> Scoreboard
Monitor -observed outputs-> Scoreboard
Reference model -finished packets-> Coverage
```

| File | Plain-words role |
|---|---|
| `cp_decoder_interface.sv` | the bundle of wires between testbench and DUT |
| `cp_decoder_transactions.sv` | `cp_pkt`: one packet (kind, register, opcode, count, random payload, idle gap) with the constraints that shape random traffic; `cp_dw_item`: one accepted dword; `cp_out_item`: one observed output; `cp_pkt_obs`: a finished packet for coverage |
| `cp_decoder_config.sv` | `ready_pct`: how often the downstream accepts a payload word |
| `cp_decoder_sequences.sv` | `cp_rand_seq` (random packets, all knobs adjustable) and `cp_directed_seq` (every corner in a fixed order) |
| `cp_decoder_driver.sv` | sends header then payload with valid/ready; a parallel thread wiggles `out_ready` randomly |
| `cp_decoder_monitor.sv` | samples every cycle; publishes accepted input dwords first, then outputs |
| `cp_decoder_agent.sv` | groups sequencer, driver and monitor |
| `cp_decoder_reference_model.sv` | an independent parser of the same dwords that predicts every output |
| `cp_decoder_scoreboard.sv` | in-order comparison of expected vs actual |
| `cp_decoder_coverage.sv` | 28 bins on packet kinds, counts, opcodes, stalls, register wrap and packet ordering |
| `cp_decoder_assertions.sv` | 8 SVA properties checked every cycle |
| `cp_decoder_env.sv` | builds and connects the pieces |
| `cp_decoder_tests.sv` | five tests (below) |
| `cp_decoder_pkg.sv`, `cp_decoder_tb_top.sv` | package that includes the classes; top module with clock, reset, DUT, assertions and the text waveform writer |
| `Makefile` | `make regress`, `make bugs` |

## Verification decisions and why

**What we check, in one sentence.** Every accepted dword produces exactly the right output (or the right absence of output), in order, under any backpressure, and illegal headers raise the error flag exactly once.

| Decision | Why |
|---|---|
| The reference model parses the dwords the **monitor** saw, not the packets the sequence sent | The model then checks the DUT against what really crossed the pins. If the driver had a bug and dropped a word, a sequence-based prediction would blame the DUT wrongly or hide the driver bug. |
| One monitor samples input and output in the same cycle, input first | A payload word and its output appear in the same cycle. If two monitors raced, the scoreboard could receive the output before the model had predicted it and report a false error. Fixing the order removes the race. |
| In-order scoreboard (a simple queue) | The decoder never reorders: output N always comes from input N. An in-order queue is the strictest possible check. A single extra, missing or swapped output fails immediately, with the exact expected and actual values printed. |
| Every output kind is compared field by field (address + data for REG; opcode + data + last for OP) | A wrong address with right data is the most likely bug (it is the one planted as `BUG_T4_NOINC`); checking only data would miss it. |
| `bad_pkt` is checked as an **event** (the cycle it rises), expected only for the first illegal header | The flag is sticky, so a second bad header must not create a new event. The SVA `a_bad_sticky` separately checks it never drops. |
| Monitor samples at the falling edge, driver changes signals just after the rising edge | All combinational outputs have settled half a cycle before sampling. This removes simulator race conditions without needing clocking blocks. |
| The end-of-test check requires the expected queue to be empty | Catches the bug where the DUT silently stops producing outputs (a hang); without it a test with missing outputs at the end would pass. |
| Payload data is fully random 32-bit | Data words that happen to look like headers (`0x4.......`, `0x7.......`) must be treated as data. Random data hits that case constantly. |
| Idle gaps between packets (0 to 3 cycles) | Proves the decoder does not depend on back-to-back traffic and does not misread an idle bus. |
| Random `out_ready` from 25% to 100% | Low acceptance stretches each payload word over many cycles; the decoder must hold its state. Even at 80%, 345 of 399 packets with a payload saw at least one stall in `cp_rand_test` seed 1. |

**Why these coverage bins.** Coverage answers "did the tests actually create the dangerous situations?"

| Bin group | Why it matters |
|---|---|
| kind T4 / T7 / BAD | each path of the header decode |
| counts zero / one / few / mid / max (127 for T4) | zero is the classic off-by-one; one is the shortest real payload; max tests the full 7-bit field |
| opcode dispatch / event_write / wait_idle / other | the three real operations, and that unknown opcodes still pass through untouched |
| payload stalled / not stalled | backpressure really happened in the middle of a payload |
| t4 register wrap | the 18-bit address wrapped from `0x3FFFF` to 0 inside one packet |
| order X then Y (9 bins) | every pair of packet kinds back to back, especially BAD then a good packet (the recovery path) |

**Coverage found a testbench bug.** The first regression showed `t4_count_zero` and `t4_reg_wrap` at 0 hits even though the constraints asked for them. The cause: in a `dist`, `[1:8] := 70` gives weight 70 to **each** of the 8 values, which drowned out `0 := 5`. Changing range weights to `:/` (weight shared across the range) fixed it. Without coverage, the tests would have looked fine and never generated a zero-count packet randomly.

**Why these assertions.**

| Assertion | Rule | Why it is an assertion, not a scoreboard check |
|---|---|---|
| `a_one_output` | never a register write and an opcode word in the same cycle | a cycle-level structural rule |
| `a_out_needs_xfer` | an output only on a cycle where a payload word is actually transferred | catches outputs that fire while `out_ready` is low (the scoreboard would see the right values and pass) |
| `a_hdr_ready` | `dw_ready` is 1 whenever no packet is in progress | a performance and liveness rule; the scoreboard does not see bubbles |
| `a_payload_ready` | in a payload, `dw_ready` equals `out_ready` | no extra bubbles and no overrun |
| `a_bad_sticky` | `bad_pkt` never falls without reset | the scoreboard only watches the rising edge |
| `a_last_on_op` | `op_last` only with `op_valid` | |
| `a_in_stable` | a stalled input word stays valid and unchanged | checks the **driver** obeys valid/ready, so a testbench bug cannot hide as a DUT bug |
| `a_no_x` | no X on control outputs after reset | X can pass a `==` compare silently in some flows |

## Tests and why each exists

| Test | Knobs | Purpose |
|---|---|---|
| `cp_directed_test` | 10 hand-picked packets | every corner exactly once: count 1, zero-count type 4 and type 7, register wrap, count 127, bad header, recovery, second bad header |
| `cp_rand_test` | 400 packets, gaps 0-3, ready 80% | general random traffic |
| `cp_backpressure_test` | 300 packets, ready 25% | long stalls inside payloads |
| `cp_bad_pkt_test` | 15% illegal headers | error path and recovery under random traffic |
| `cp_corner_test` | high weights for zero, max count and register wrap | pushes rare corners in random order |

## Results

| Item | Result |
|---|---|
| Regression | 5 tests x 3 seeds = 15 runs, all PASS (0 UVM_ERROR, 0 UVM_FATAL) |
| Outputs compared | 138 (directed) up to 14,323 (random) per run, 0 mismatches |
| Merged functional coverage | 100% (28 of 28 bins) |
| `BUG_T4_NOINC` (register address not incremented) | **caught**: first error `expected REG addr=074d8, actual REG addr=074d7` |
| `BUG_ZERO_COUNT` (count 0 still enters S_T4) | **caught**: the next header is wrongly written as a register (`unexpected output: REG addr=00200 data=70010000`) |

## What is not verified here

- Parity bits of real PM4 headers are ignored by design.
- The decoder never sees a reset in the middle of a packet in these tests; that is covered later at CP level.
- Register access protection (user rings writing protected registers) belongs to the SQE/RBBM blocks.

# Teaching section: the packet decoder in context

## The block and its pins

```pins
block: Packet decoder | cp_packet_decoder.sv · 1 dword per accepted cycle · 3-state FSM
in: dw_valid / dw_ready, dw_data | cp_ring_fetch | one 32-bit command dword offered / decoder can take it
in: out_ready | cp_sqe (op_ready) | the SQE can take a payload dword; register writes wait on it too, to stay in order
out: reg_wr_en, reg_wr_addr, reg_wr_data | dispatcher, top-level control registers | type 4: write one register this cycle
out: op_valid, op_code, op_data, op_last | cp_sqe | type 7: one payload dword of an operation, op_last on the final one
out: bad_pkt | rbbm (ev_bad_pkt) | sticky: an illegal header was seen
out: busy | top busy bit 3 | inside a packet (not waiting for a header)
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the command processor

```hflow
RBBM | ring base and WPTR -wptr-> Ring fetch | reads ring lines -dwords-> Packet decoder | splits packets | you -ops-> SQE | runs DISPATCH, fence, wait -launch-> Dispatcher | workgroups to SMs
```

The decoder is the **second stage of the command processor (CP)**. The ring fetch only knows about dwords; the SQE only knows about operations. The decoder is the piece that understands the packet *framing*: which dword is a header, how many dwords belong to it, and whether they are register writes (type 4) or operation payload (type 7).

| Stage | Unit of work | Knows about |
|---|---|---|
| Ring fetch | 32-byte line from memory, then single dwords | addresses, ring pointers |
| Packet decoder | one dword at a time | headers, counts, type 4 vs type 7 |
| SQE | one whole operation (opcode + up to 2 arguments) | what DISPATCH, EVENT_WRITE, WAIT_FOR_IDLE mean |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Ring fetch (02) | dw_* in | Supplies the dword stream from its FIFO. Every pop moves `rptr`, which the CPU can read back through the RBBM. |
| SQE (03) | op_* out, out_ready in | Receives operation dwords. Its `op_ready` is wired to `out_ready`, so a busy SQE stalls the decoder. |
| Dispatcher (05) | reg_wr_* out | Picks up registers 0x100-0x102 (kernel pc, warps per workgroup, argument base). |
| mgpu_top control registers | reg_wr_* out | Registers 0x200-0x205: page table base, MMU enable, TLB invalidate, L2 flush, GMU idle limit, MMU fault clear. |
| RBBM (04) | bad_pkt out | Turns the rising edge of the sticky flag into IRQ_STATUS bit 1. |
| Top-level busy / progress | busy, and the dw_valid && dw_ready handshake | Busy bit 3 is `rf_busy || dec_busy`; every accepted dword counts as forward progress for the hang detector and as a perf event. |

## Design details

- **Three states.** `S_HDR` waits for a header, `S_T4` streams register writes, `S_T7` streams operation payload. A 14-bit `remain` counter says how many payload dwords are still expected, and the FSM returns to `S_HDR` when the last one is taken.
- **No buffering at all.** Outputs are combinational from the input dword: `reg_wr_data = dw_data` and `op_data = dw_data`. The decoder only stores the small header context (`cur_reg`, `cur_op`, `remain`). That makes it cheap and adds zero latency, but it means the downstream stall goes straight back to the ring fetch.
- **Ready rule.** `dw_ready` is 1 in `S_HDR` (a header is always consumed internally) and equals `out_ready` inside a packet. So a header never waits, and payload waits for the SQE.
- **Register writes wait for the SQE too.** In the top, `out_ready` is the SQE's `op_ready`. A type 4 write after a DISPATCH therefore cannot slip ahead while the SQE is still busy with that DISPATCH. This is what keeps "program kernel B" behind "launch kernel A" in program order.
- **Auto-increment.** Type 4 writes consecutive registers: `cur_reg` goes up by one after each payload dword, so one header can program 0x100, 0x101 and 0x102.
- **Zero-count packets.** A type 4 or type 7 header with count 0 goes straight back to `S_HDR` and produces no output. That is why every operation in this ISA carries at least one payload dword.
- **Illegal headers.** Anything whose top nibble is not 4 or 7 sets the sticky `bad_pkt` flag and is otherwise skipped; the decoder stays in `S_HDR` and treats the next dword as a header. Only reset (or soft reset) clears the flag.

## Questions: what if we did it differently?

**Q1. What if we supported PM4 type 3 packets instead of (or as well as) type 7?**
Type 3 is the older AMD-style operation packet; its header uses a different layout for opcode and count. In hardware this is just another branch in the `S_HDR` decode, with its own bit fields feeding `cur_op` and `remain`. You gain compatibility with older command streams, but the header decode grows and you have two encodings for the same operation. The testbench would need a second header builder in its packet model and a scoreboard that maps both encodings to the same expected operations.

**Q2. What if register writes went through their own path instead of waiting on `out_ready`?**
Register writes would then never stall. That improves throughput when the SQE is stuck in a long WAIT_FOR_IDLE, but it breaks ordering: a kernel's configuration could be overwritten while the previous DISPATCH is still being accepted. The dispatcher latches its configuration on accept, which saves the kernel registers, but the MMU and L2 flush registers have no such protection. To make it safe you would need a "register write fence" in the SQE. The testbench would need a new ordering check: a register write must not appear before the preceding operation's `op_done`.

**Q3. What if the decoder had an output FIFO instead of being purely combinational?**
A small FIFO would decouple the ring fetch from SQE stalls, so the fetch could keep reading ahead. It costs flops and adds a cycle of latency, and it complicates `busy` (the FIFO must count as busy). It would also make "register writes stay in order with operations" harder unless both kinds go through the same FIFO. The testbench would need to model the extra latency and drop any cycle-exact expectations.

**Q4. What if illegal headers stopped the decoder instead of being skipped?**
That is a "halt on error" policy, common in real CPs, because after a bad header you cannot know where the next real header is. Halting is safer (nothing random gets executed), skipping is simpler and keeps the chip alive. With halting, recovery needs a soft reset from the CPU. The testbench would change its expectation from "keep decoding the next dword as a header" to "accept nothing until reset".

**Q5. What breaks with `BUG_ZERO_COUNT`?**
A type 4 header with count 0 moves to `S_T4` anyway. With `remain = 0`, the next dword (really the next header) is taken as a register write, and the decrement wraps the 14-bit counter, so the decoder then swallows thousands of dwords as register writes. The symptom is unexpected register writes and lost packets after any zero-count type 4 header. A test that sends a zero-count packet followed by a normal packet finds it at once.

**Q6. What breaks with `BUG_T4_NOINC`?**
`cur_reg` does not increase, so a three-register write hits the first register three times. For the vector-add launch packet, KERNEL_PC would end as the argument base and WARPS_PER_WG and ARG_BASE would never be written. The scoreboard sees the wrong register addresses on `reg_wr_addr`. Tests with count 1 cannot catch it; the test needs counts of at least 2.

**Q7. What if the header count were a full 14 bits for type 4 too?**
Type 4 uses only 7 bits of count (`[6:0]`), so one packet can write at most 127 registers. A larger count saves headers when loading big register tables, at the cost of fewer bits for other fields. The hardware change is just the width of the slice; the testbench's random packet generator would need to cover the new upper range.

**Q8. What if the CPU wrote registers through MMIO (the RBBM) instead of type 4 packets?**
MMIO writes take effect immediately, outside the command stream. That is simpler, but the CPU would have to wait for the GPU to be idle before changing a kernel's configuration. Putting the writes in the ring makes them happen *in order* with the commands around them, so the CPU can queue several kernels without waiting. That ordering is the main reason type 4 packets exist.

**Q9. Could the decoder process two dwords per cycle?**
Yes, if the ring fetch could deliver two. You would need to handle a header and its first payload dword in the same cycle, and two register writes per cycle on the bus. Throughput doubles, but for a command processor that is rarely the bottleneck: one launch packet starts thousands of threads. The testbench driver and scoreboard would need to handle a 2-wide interface.
