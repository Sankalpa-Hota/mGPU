# 19 GBIF (bus interface to AXI4)

## What this block is, in plain words

Inside the GPU everything moves in 32-byte lines; outside, the memory controller speaks **AXI4**, the standard SoC bus. GBIF translates: a line read becomes one AXI read burst of 8 beats of 4 bytes; a line write becomes one write burst of 8 beats with byte strobes, followed by a write response. Bus errors come back to the requester.

## AXI4 in one paragraph

Five independent channels, each with its own valid/ready handshake: AR (read address), R (read data, RLAST on the last beat), AW (write address), W (write data with strobes, WLAST on the last beat), B (write response). A burst never crosses a 4 KB boundary. One rule is easy to get wrong: a **master must not wait for AWREADY before driving WVALID**, because a slave is allowed to wait for write data before accepting the address. A master that waits deadlocks with such a slave.

## RTL decisions and why

| Decision | Why |
|---|---|
| One burst per line: INCR, 8 beats, 4 bytes | Lines are aligned, so a burst never crosses 4 KB. |
| AW and W driven at the same time; the response is awaited only when both are done | The deadlock rule above (`BUG_W_AFTER_AW` waits for AW first). |
| WLAST exactly on beat 8 | Protocol (`BUG_WLAST`). |
| Any non-OKAY RRESP or BRESP sets `err` for the line | Errors are never silently dropped. |
| First version: after the 8th W beat the beat counter wrapped and could send extra beats if AW had not been accepted yet | Found by reading the code before simulation; rewritten with separate "address done" and "data done" flags. |

## Verification decisions and why

| Decision | Why |
|---|---|
| Generic AXI protocol checker (`axi_protocol_checker.sv`, also used for block 20): stable payloads, WLAST/RLAST position, 4 KB rule, no X | Protocol bugs are caught where they happen, independent of data. |
| AXI slave model with **independent** AW and W processes and an option to accept AW only after seeing write data | Exercises every legal ordering: AW first, W first, both in the same cycle. The first slave model always took AW before W, which left half of the orderings untested. |
| Error injection on R and B | Error propagation. |

Two testbench mistakes found here: the AXI checker first declared `int expect_len = ...` inside an `always_ff`, which in SystemVerilog is initialized only once at time 0, so the checker compared against a stale length; and the new slave model first lowered READY between the sampling edge and the clock edge, so it recorded handshakes the DUT never saw.

## Results

| Item | Result |
|---|---|
| Regression | 4 tests x 3 seeds = 12 runs, all PASS (3,000 lines per random run) |
| Merged coverage | 100% (11 of 11) |
| `BUG_W_AFTER_AW` | caught as a deadlock with the "wait for W" slave |
| `BUG_WLAST`, `BUG_RBEAT_ORDER` | caught by the AXI checker and the line checker |

# Teaching section: the GBIF in context

## The block and its pins

```pins
block: GBIF | gbif.sv · one 32-byte line = one 8-beat AXI4 INCR burst · one transaction at a time
in: req_valid / req_ready | MMU | a physical line request / GBIF is idle
in: req_addr, req_we, req_wdata, req_wstrb | MMU | line address, read or write, 256-bit line, 32 byte strobes
out: rsp_valid, rsp_data, rsp_err | MMU | the read line (or write done); err = 1 if any RRESP/BRESP was not OKAY
out: araddr, arlen, arsize, arburst, arvalid / arready | DRAM controller (AR channel) | read address: len 7, size 2, INCR
in: rdata, rresp, rlast, rvalid / rready | DRAM controller (R channel) | eight 32-bit read beats
out: awaddr, awlen, awsize, awburst, awvalid / awready | DRAM controller (AW channel) | write address: len 7, size 2, INCR
out: wdata, wstrb, wlast, wvalid / wready | DRAM controller (W channel) | eight 32-bit write beats with 4 strobes each
in: bresp, bvalid / bready | DRAM controller (B channel) | write response
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the memory path

```hflow
Line arbiter | one of four requesters -virtual line-> MMU | translate -physical line-> GBIF | line to burst | you -AXI4 bursts-> DRAM controller | memory array
```

The GBIF is the **edge of the GPU**. Inside, everything moves in 256-bit lines with a simple valid/ready request and a response. Outside, the world speaks AXI4 on a 32-bit bus. The GBIF converts one into the other:

| Request | AXI activity | Ends when |
|---|---|---|
| Read | one AR (`arlen = 7`, `arsize = 2`, `arburst = INCR`), then 8 R beats | 8th R beat accepted, then one cycle in DONE |
| Write | AW and the 8 W beats offered at the same time, `wlast` on beat 8 | B response accepted, then DONE |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| MMU (18) | req_* in, rsp_* out | Sends page-walk reads and translated line reads/writes; gets lines back. |
| DRAM controller (20) | all AXI channels | The AXI4 slave on the other side. In `mgpu_system` the GBIF's AXI ports are wired straight to it. |
| mgpu_top ports | ar*, r*, aw*, w*, b* | The GBIF's AXI pins are the GPU's external memory pins; any AXI4 slave could be attached. |
| L2, CP fetch, SQE (indirectly) | rsp_err travels up through the MMU | A bus error becomes `rsp_err` on the line response. |

## Design details

- **Width conversion.** A line is 256 bits; the bus is 32 bits. So each line is 8 beats. `arlen`/`awlen` are fixed at 7 (AXI encodes "beats minus one"), `arsize`/`awsize` at 2 (2^2 = 4 bytes per beat), burst type INCR. These are wired as constants.
- **Line alignment.** The address is forced to a 32-byte boundary (`{req_addr[31:5], 5'd0}`), so a burst never crosses a line, and never crosses AXI's 4 KB boundary rule.
- **FSM.** IDLE, AR, R, W, B, DONE. Reads go IDLE, AR, R, DONE. Writes go IDLE, W, B, DONE. A 3-bit `beat` counter selects which 32-bit slice to send or where to store a received beat.
- **AW and W together.** In state W both `awvalid` and `wvalid` are raised at once, tracked by two flags `aw_done` and `w_done`. The FSM leaves W only when both the address was accepted and the last data beat was accepted, in whatever order the slave chose. This follows the AXI rule that a master must not wait for AWREADY before driving WVALID.
- **Strobes per beat.** Beat n carries `wstrb = req_wstrb[4n+3 : 4n]`, so a partial line write (the SQE fence write, for example) only changes the bytes that were meant.
- **Errors are collected, not fatal.** Any non-OKAY RRESP on any beat, or a non-OKAY BRESP, sets a sticky `err` flag that is reported once in DONE as `rsp_err`. The burst is still completed, as AXI requires.
- **Single ID, single outstanding transaction.** No AXI ID ports exist (ID 0 implied). `req_ready` is high only in IDLE.

## Questions: what if we did it differently?

**Q1. What if the GBIF allowed several outstanding transactions with AXI IDs?**
Today one line read waits the full DRAM latency before the next starts. With ARID/AWID and, say, 4 outstanding reads, the GBIF could issue the next AR while earlier R data is still coming, hiding the DRAM latency. Hardware: a table of outstanding transactions, per-ID response routing, and the MMU above would need to accept out-of-order responses (AXI may reorder responses with different IDs). Throughput rises sharply; complexity and buffering rise too. The testbench would need an AXI slave model that reorders by ID and a scoreboard that matches responses by ID.

**Q2. AXI4 versus AHB versus CHI?**
AHB is a simpler pipelined bus with one shared address/data phase and no separate read and write channels; it cannot overlap reads and writes and is meant for low-bandwidth peripherals. AXI4 (ours) has five independent channels and supports outstanding and out-of-order transactions. CHI is a packet-based coherent protocol for many-core interconnects with snoops and home nodes; it would be needed if the GPU shared coherent memory with CPUs. Changing protocol changes every pin of this block and requires a new protocol VIP in the bench.

**Q3. INCR versus WRAP bursts?**
WRAP bursts start at the critical word and wrap around inside the aligned line, so the word the core actually needs arrives first ("critical word first"). Our GBIF always fetches the whole line from word 0, so a miss on word 7 waits for 8 beats. Using WRAP needs the unaligned start address and a beat-to-slot mapping that wraps, and the cache could wake the waiting thread early. Note: our DRAM controller rejects WRAP with SLVERR, so it would need changing too.

**Q4. What about a wider bus (64, 128, 256 bits)?**
A 256-bit bus moves a line in one beat: 8 times less transfer time and no beat counter, at the cost of 8 times more wires and a wider memory. Real GPU memory interfaces are very wide (many channels). `arsize`, `arlen` and the slicing logic all change; the DRAM model must change width too.

**Q5. Why not wait for AWREADY before raising WVALID? (`BUG_W_AFTER_AW`)**
That is exactly the bug. A legal AXI slave may wait to see write data before it accepts the address. If the master waits for AWREADY first and the slave waits for WVALID first, both wait forever: a deadlock. Our DRAM controller happens to accept AW first, so the bug may hide with it; the bench needs an AXI slave that sometimes holds AWREADY low until it has seen W data. Our GBIF bench has exactly that "wait for W" slave mode, and that is how `make bugs` caught it (the run hangs and the timeout fires).

**Q6. What does `BUG_WLAST` do?**
`wlast` is raised on beat 7 (index 6) instead of beat 8. The slave treats the burst as finished one beat early: our DRAM controller moves to the response state after 7 beats, so the 8th word is never written, and the GBIF still tries to send an 8th beat that nobody accepts, which can hang. An AXI protocol checker flags it immediately (WLAST must match AWLEN).

**Q7. What does `BUG_RBEAT_ORDER` do?**
Read beats are stored in reverse slots (beat 0 into word 7). Every read line comes back with its 32-bit words reversed, so loads return the wrong value unless all 8 words happen to be equal. A memory initialised with zeros or a constant would hide it; the test needs distinct data per word.

**Q8. What if responses were reported per beat instead of per line?**
We merge all eight RRESPs into one `rsp_err`. A design could report which beat failed, letting the cache keep the good words. That adds bits to the response and almost never pays off, because an error usually means the whole address range is bad (DECERR) or the request was malformed (SLVERR).
