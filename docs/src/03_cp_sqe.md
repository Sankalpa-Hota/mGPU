# 03 CP SQE (operation sequencer)

## What this block is, in plain words

The packet decoder (block 01) splits commands into two kinds. Register writes go straight to the configuration registers. **Operations** (type 7 packets) go to the **SQE**, a small sequencer that actually *does* things:

- **DISPATCH**: "start the kernel now, with this many workgroups". The SQE hands the request to the dispatcher (block 05).
- **EVENT_WRITE**: "write this fence value to this address, then interrupt the CPU". This is how the CPU learns that a job has finished: it waits for the interrupt and then reads the fence value from memory.
- **WAIT_FOR_IDLE**: "do not start anything else until these parts of the GPU are idle". The driver puts it between jobs that depend on each other, and before an EVENT_WRITE so that the fence really means "everything before me is done".

The SQE does one operation at a time, in order. While it works it tells the decoder "not ready", so commands queue up behind it.

## Where it sits and who talks to it

```hflow
Packet decoder -opcode dwords-> SQE -start kernel-> Dispatcher
SQE -fence write-> Memory
SQE -interrupt-> RBBM
```

| Who | Talks to | For what | Signals |
|---|---|---|---|
| Packet decoder | SQE | opcode and payload dwords of a type 7 packet | `op_valid`, `op_ready`, `op_code[6:0]`, `op_data[31:0]`, `op_last` |
| SQE | dispatcher | start a kernel with N workgroups | `disp_valid`, `disp_ready`, `disp_num_wg[31:0]` |
| Every block | SQE | "I still have work" | `busy_in[7:0]` (bit 0 = dispatcher and SMs) |
| SQE | memory | write one dword (the fence) | memory port with `mreq_we = 1`, `mreq_wdata`, `mreq_wstrb`; `mrsp_valid` = write acknowledged |
| SQE | RBBM | job-done interrupt; error flag; status | `irq` (one-cycle pulse), `bad_op` (sticky), `busy`, `op_done` (one-cycle pulse per finished operation, for perf counters) |

## Operations and their payload

| Opcode | Operation | Payload dword 0 | Payload dword 1 | Effect |
|---|---|---|---|---|
| 0x01 | DISPATCH | number of workgroups | - | one dispatch handshake |
| 0x02 | EVENT_WRITE | fence byte address (dword aligned) | fence value | one masked memory write; one IRQ after the write is acknowledged |
| 0x03 | WAIT_FOR_IDLE | busy mask (bit i = wait for `busy_in[i]`) | - | waits; no other effect |
| other | illegal | - | - | sets `bad_op`; no other effect |

Extra payload dwords (beyond what the operation needs) are accepted and ignored, so a newer driver that adds fields does not break this hardware.

## Architecture

```tree
cp_sqe | one operation at a time | root
  Collect stage | gathers arg0 and arg1 from the payload dwords | comp
  Execute FSM | DISPATCH, WFI_SETTLE, WFI, EW_REQ, EW_ACK, DROP | comp
  Settle counter | waits SETTLE cycles before trusting busy bits | comp
  Write formatter | line address, byte strobes, data replicated on every dword lane | comp
  Status | irq pulse, op_done pulse, sticky bad_op, busy | comp
```

```flow
box: COLLECT | op_ready = 1; latch arg0, arg1; on op_last choose by opcode
arrow: DISPATCH
box: DISPATCH | disp_valid = 1 until disp_ready | hw
arrow: accepted: op_done
back: back to COLLECT (WAIT_FOR_IDLE: WFI_SETTLE for SETTLE cycles, then WFI until (busy_in & mask) == 0; EVENT_WRITE: EW_REQ until accepted, EW_ACK until acknowledged, then irq + op_done; unknown: DROP for one cycle)
```

## RTL decisions and why

| Decision | Why |
|---|---|
| One operation at a time, `op_ready` low while executing | Operations have ordering meaning (wait, then write the fence). Executing in order with no overlap makes that meaning automatic. |
| Every operation needs at least one payload dword | A type 7 packet with count 0 produces no output from the decoder, so the SQE would never see it. WAIT_FOR_IDLE therefore carries its mask as a payload dword. |
| **Settle window** before WAIT_FOR_IDLE samples busy bits (SETTLE = 3) | Blocks are pipelined: the dispatcher accepts a job and raises its busy bit a few cycles later. If WFI looked at busy right away it could see "idle" for work that has just been started and let the fence be written too early. The contract is "a block raises busy no later than SETTLE cycles after accepting work"; the SQE waits that long. This is planted as `BUG_WFI_NO_SETTLE`. |
| IRQ only after the write **acknowledge**, not after the request is accepted | The CPU reads the fence when the IRQ arrives. If the IRQ came first, the CPU could read the old value and think the job is not done (or worse, sleep forever). Planted as `BUG_IRQ_BEFORE_ACK`. |
| Fence write uses byte strobes for exactly one dword, data copied to every lane | The memory port moves whole lines; strobes make sure only the 4 fence bytes change and the other 28 bytes of the line are untouched. Copying the data everywhere means the lane select is only in the strobes, one place to get right. Planted as `BUG_STRB` (wrong address bits used for the lane). |
| Unknown opcode: one cycle in DROP, then `bad_op` | The first version finished unknown ops without leaving COLLECT; the assertions showed this broke the "accept, execute, done" pattern every other op follows (two unknown ops back to back made `op_done` two cycles long). A one-cycle state makes the protocol uniform. |
| `op_done` pulse per operation | Lets performance counters count operations and measure WFI time without knowing the opcode. |

## Waveform (from the simulation)

WFI race test, cycles 10 to 19 (column 0 of the figure is cycle 10; DSP = DISPATCH state, COL = COLLECT). The dispatch handshake happens in cycle 10 (`op_done` follows in cycle 11). WAIT_FOR_IDLE with mask 1 is accepted in cycle 11, the very next cycle. The dispatcher model raises `busy_in[0]` only in cycle 13, three cycles after the handshake. The SQE is still in its settle window (cycles 12 to 14), so it does not miss the job: it waits in WFI until busy falls in cycle 18 and finishes in cycle 19. Without the settle window (`BUG_WFI_NO_SETTLE`) it would have sampled busy in cycle 12, seen 0, and finished while the job was still running.

```wave
clk        | pppppppppp
state      | ===..=...=| DSP COL SETTLE WFI COL
disp_valid | 1000000000
op_ready   | 0100000001
busy_in[0] | 0001111100
op_done    | 0100000001
```

## RTL file

| File | What is inside |
|---|---|
| `rtl/03_cp_sqe/cp_sqe.sv` | collect stage, execute FSM, settle counter, write formatter; planted bugs `BUG_WFI_NO_SETTLE`, `BUG_IRQ_BEFORE_ACK`, `BUG_STRB` |

## Testbench architecture

```hflow
Sequence -operations-> Op driver (plays decoder) -opcode dwords-> DUT
DUT -dispatch-> GPU model (busy bits) -busy_in-> DUT
DUT -fence write-> Memory model -ack-> DUT
```

```hflow
Monitor -operations-> Scoreboard
Monitor -side effects-> Scoreboard
GPU model -job ended-> Scoreboard
```

| File | Plain-words role |
|---|---|
| `sqe_interface.sv` | the wires |
| `sqe_config.sv` | knobs: dispatcher readiness, job length, how late busy rises (up to SETTLE), background busy rate, memory readiness and ack latency |
| `sqe_transactions.sv` | `sqe_op` (opcode, args, payload count, gap) and `sqe_event` (one observed side effect with its cycle) |
| `sqe_sequences.sv` | `sqe_rand_seq`, `sqe_wfi_race_seq` (DISPATCH then WFI back to back, 40 times), `sqe_event_seq` (fence to every dword lane, then random) |
| `sqe_op_driver.sv` | plays the decoder |
| `sqe_responders.sv` | `sqe_gpu_model`: turns each dispatch into a job on `busy_in[0]` (rising 1 to SETTLE cycles late) plus background jobs on bits 1-7, and reports when each dispatch job really ends; `sqe_memory_model`: accepts the fence write and acknowledges it after a random latency |
| `sqe_monitor.sv` | rebuilds each operation and stamps every side effect with its cycle |
| `sqe_scoreboard.sv` | per-operation effect checks (below) |
| `sqe_coverage.sv` | 26 bins |
| `sqe_assertions.sv` | 10 SVA properties |
| `sqe_env.sv`, `sqe_tests.sv`, `sqe_pkg.sv`, `sqe_tb_top.sv`, `Makefile` | wiring, six tests, package, top |

## Verification decisions and why

**What we check, in one sentence.** Each operation causes exactly its own side effects and nothing else, with the right values, in the right order relative to the memory acknowledge, and WAIT_FOR_IDLE never finishes while work it should wait for is still running.

| Decision | Why |
|---|---|
| Scoreboard groups side effects by the operation in progress | The SQE is strictly one-at-a-time, so every effect between "accepted" and `op_done` belongs to the current op. A dispatch during an EVENT_WRITE, or two IRQs for one fence, are caught immediately. |
| Every side effect carries its cycle number | Ordering bugs (IRQ before ack, WFI finishing before a job ends) are *timing* bugs: the values are right, the moment is wrong. Only timestamps can catch them. |
| The GPU model reports when each dispatched job **really** ended | The true question for WFI is "has the work I am waiting for finished?", not "were the busy bits low?". Checking busy bits alone would trust the same signal the DUT trusts. Comparing against the real job end catches a WFI that finishes during the busy-rise delay. |
| Busy rises 1 to SETTLE cycles late in the model, never later | That is the contract. Testing beyond the contract would report failures that are the other block's fault. Testing the full range up to the limit is what makes the race visible. |
| The WFI busy-bit check uses the busy value of the cycle before `op_done` | That is the value the DUT sampled when it decided. Using the current value would race with background jobs that start in the same cycle. |
| Fence check covers line address, strobes and the data lane separately | Each has its own bug: wrong line, wrong bytes enabled, value in the wrong lane. One combined compare would not say which. |
| Background busy bits 1-7 with random masks | Proves WFI only waits for the selected bits: a mask of 0 must finish at once, a mask of 0xFF must wait for everything. |
| Drain at the end, then stop background jobs and wait for every busy bit | A WFI that never finishes would otherwise end the test silently; stopping background traffic first lets a legitimate wait end. |

**Why these coverage bins.**

| Bins | Why |
|---|---|
| op_dispatch / event_write / wfi / unknown | every path |
| ew_offset_0 to ew_offset_7 | the fence lands in every dword lane of a line; strobe bugs are usually lane specific |
| ew_extra_payload | forward compatibility: extra dwords are ignored |
| wfi_mask zero / all / single / other | the mask logic at its extremes |
| wfi_wait min / short / long | WFI that ends right after settle, after a short wait, after a long wait |
| wfi_right_after_dispatch | the race case: WFI accepted within 2 cycles of a dispatch handshake |
| disp_backpressure, mem_req_backpressure, ack fast / slow | each wait state of the FSM really waited |
| op_back_to_back | a new operation accepted within 2 cycles of the previous `op_done` |

**Why these assertions.**

| Assertion | Rule | Why |
|---|---|---|
| `a_hold_input` | after the last payload dword, `op_ready` is low | one-at-a-time; it is what caught the unknown-opcode inconsistency |
| `a_disp_stable`, `a_req_stable` | requests held unchanged until accepted | valid/ready rule on both outputs |
| `a_one_request` | never dispatch and memory write at once | one operation at a time |
| `a_irq_pulse`, `a_done_pulse` | pulses are one cycle | RBBM counts pulses; a 2-cycle pulse would count twice |
| `a_one_strobe_dword` | fence write enables exactly 4 bytes | never corrupt neighbours in the line |
| `a_bad_sticky` | `bad_op` never falls | |
| `a_in_stable` | stalled input stays stable | checks the driver |
| `a_no_x` | no X on outputs | |

## Tests and why each exists

| Test | Purpose |
|---|---|
| `sqe_smoke_test` | 30 random operations, everything fast |
| `sqe_rand_test` | 500 operations, 60% dispatcher and memory readiness, slow acks, some background busy |
| `sqe_wfi_race_test` | DISPATCH immediately followed by WFI on bit 0, busy rising late, 40 times |
| `sqe_event_test` | fence to every lane, then random, slow memory |
| `sqe_unknown_op_test` | 15% illegal opcodes mixed with real ones |
| `sqe_busy_storm_test` | heavy background busy with random masks |

## Results

| Item | Result |
|---|---|
| Regression | 6 tests x 3 seeds = 18 runs, all PASS |
| Operations checked | 30 to 500 per run (500 operations with 180 dispatches in `sqe_rand_test`), 0 errors |
| Merged functional coverage | 100% (26 of 26 bins) |
| `BUG_WFI_NO_SETTLE` | **caught**: `WAIT_FOR_IDLE ... finished at cycle 93 but dispatch #11 (cycle 90) was still running` |
| `BUG_IRQ_BEFORE_ACK` | **caught**: `EVENT_WRITE ... IRQ at cycle 12 but write ack only at cycle 13` |
| `BUG_STRB` | **caught**: `byte strobes 0000000f, expected 000f0000` |
| Found during bring-up | the unknown-opcode protocol inconsistency (fixed in RTL, see RTL decisions) and a testbench drain bug in the busy-storm test (background jobs never stopped) |
| Tool limitation found | Verilator treats `dist` as a hard choice of bucket, so an inline `with` that fixes a field covered by a `dist` fails to solve. Directed items set fields directly instead. |

## What is not verified here

- How the real dispatcher and SMs drive `busy_in`: the contract (busy within SETTLE cycles) is checked again when the dispatcher (block 05) is verified, and at full-chip level.
- Memory errors on the fence write (no error response on the memory port yet).

# Teaching section: the SQE in context

## The block and its pins

```pins
block: SQE | cp_sqe.sv · 7-state FSM · 3 opcodes · SETTLE = 3
in: op_valid / op_ready, op_code, op_data, op_last | cp_packet_decoder | one payload dword of a type 7 operation
in: busy_in[7:0] | busy bits from all blocks | which parts of the GPU are still working (for WAIT_FOR_IDLE)
in: disp_ready | dispatcher | dispatcher accepted the DISPATCH (it was idle)
in: mreq_ready, mrsp_valid | below-L2 arbiter | fence write accepted / fence write acknowledged
out: disp_valid, disp_num_wg | dispatcher | start a kernel with N workgroups
out: mreq_valid, mreq_addr, mreq_we, mreq_wdata, mreq_wstrb | below-L2 arbiter | the EVENT_WRITE fence: one masked 32-bit write
out: irq | rbbm (ev_fence) | one-cycle pulse after the fence write is acknowledged
out: op_done | top progress logic, perf events | an operation finished
out: bad_op | rbbm (ev_bad_op) | sticky: an unknown opcode was seen
out: busy | top | the SQE is executing or collecting an operation
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the command processor

```hflow
Ring fetch | dwords from memory -dwords-> Packet decoder | type 7 payload -ops-> SQE | executes operations | you -DISPATCH-> Dispatcher | launches workgroups -fence-> Memory | uncached write, then IRQ
```

The SQE is the **last stage of the command processor**: the part that actually *does* things. The decoder hands it an opcode with its payload; the SQE turns that into one of three actions:

| Opcode | Action | Ends when |
|---|---|---|
| 0x01 DISPATCH | offer `disp_num_wg` to the dispatcher | the dispatcher accepts (it was idle) |
| 0x02 EVENT_WRITE | write `arg1` to address `arg0` in memory, then pulse `irq` | the memory write is acknowledged |
| 0x03 WAIT_FOR_IDLE | wait SETTLE cycles, then until `(busy_in & arg0) == 0` | all selected busy bits are low |
| anything else | one cycle in `S_DROP`, set `bad_op` | immediately |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Packet decoder (01) | op_* in, op_ready out | Supplies operation dwords. `op_ready` is also the decoder's `out_ready`, so while the SQE executes, nothing else (not even register writes) moves. |
| Dispatcher (05) | disp_* | Receives the kernel launch. `disp_valid && disp_ready` is also `kernel_start` in the top, which invalidates the SM instruction caches and L1s. |
| Below-L2 arbiter in mgpu_top | mreq_*, mrsp_valid | Carries the fence write uncached to DRAM, so the CPU sees the value directly in memory. |
| RBBM (04) | irq, bad_op | `irq` sets IRQ_STATUS bit 0 (fence); the rising edge of `bad_op` sets bit 2. |
| All blocks, through mgpu_top | busy_in | Bit 0 dispatcher + SMs, bit 1 L2 (including a pending flush), bit 2 memory path below the L2, bit 3 command fetch. |
| Hang detector and perf counters | op_done | Every finished operation counts as forward progress and as a perf event. |

## Design details

- **Collect, then execute.** In `S_COLLECT` the SQE takes payload dwords. The first goes to `arg0`, the second to `arg1`, any more are ignored. On `op_last` it jumps to the state for that opcode. While it is not in `S_COLLECT`, `op_ready` is 0, so the command stream is paused until the operation finishes. This makes every operation *blocking* and strictly in order.
- **The settle window.** A block raises its busy bit a few cycles after it accepts work (for example, the dispatcher must launch and the SMs must start). If WAIT_FOR_IDLE looked at `busy_in` immediately after a DISPATCH, it could see "all idle" before the work had even begun. `S_WFI_SETTLE` waits `SETTLE = 3` cycles first. This is a *contract* written in the file header: every block must raise busy within SETTLE cycles of accepting work.
- **Fence write format.** The memory port is a 32-byte line. The SQE aligns the address down to 32 bytes, repeats the 32-bit value 8 times across the 256-bit data, and uses a byte strobe of 4 bytes at word `arg0[4:2]`. Only one word in the line is actually written.
- **Interrupt after the ack.** `irq` pulses one cycle after `mrsp_valid`, the write acknowledgment. So when the CPU gets the interrupt and reads the fence address, the value is guaranteed to be in memory. This is the classic "write the fence, then interrupt" ordering.
- **Fences ride the uncached path.** The fence goes below the L2. If it went into the L2 (a write-back cache), it might sit there and the CPU would read the old value from DRAM.
- **Unknown opcodes.** One cycle in `S_DROP`, sticky `bad_op`, `op_done` pulse, then back to work. The stream continues; the CPU learns about it through the interrupt.
- **Busy.** `busy` is high whenever the SQE is not idle in `S_COLLECT`, or is in the middle of collecting arguments (`n_args != 0`).

## Questions: what if we did it differently?

**Q1. What if the SQE were a small programmable micro-controller (microcode) instead of a fixed FSM?**
Real CPs (the AMD "ME/PFP" and the SQE of mobile GPUs) run firmware. New packets can then be added with a firmware update, not a new chip. The cost is a CPU core, an instruction memory, and a firmware loading path. Every operation becomes slower (many instructions instead of one state). The testbench would load firmware first and would test the firmware as much as the hardware.

**Q2. What if the CPU learned about completion by polling the fence instead of an interrupt?**
Polling: the CPU keeps reading the fence address until the value appears. It needs no interrupt hardware and has the lowest latency if the CPU is spinning anyway, but it wastes CPU time. Interrupts let the CPU sleep, but each interrupt has a handling cost. Our design supports both: the fence value is in memory for polling, and `irq` can be masked off with IRQ_MASK. A polling testbench would simply read DRAM in a loop and ignore `irq`.

**Q3. What if WAIT_FOR_IDLE were replaced by finer-grained barriers or semaphores?**
WAIT_FOR_IDLE stops everything until the GPU drains, which wastes the tail of each kernel. Real GPUs add *memory semaphores* (wait until a memory value reaches X) and per-engine barriers, so independent work can overlap. That needs a new opcode with a memory read and a compare loop. The testbench would need a memory model that changes the semaphore value over time and checks that the SQE waits exactly until then.

**Q4. What if DISPATCH did not block (the SQE moved on before the dispatcher accepted)?**
With a small queue of pending dispatches, the CP could run ahead and the dispatcher would always have the next kernel ready. That improves back-to-back kernel launches. But the dispatcher latches kernel config on accept, and type 4 writes would then race with queued dispatches, so each queue entry would need to carry its own configuration copy. The testbench would need to check config per queued kernel.

**Q5. What breaks with `BUG_WFI_NO_SETTLE`?**
WAIT_FOR_IDLE checks `busy_in` on the very next cycle. Right after a DISPATCH, the dispatcher and SMs may not have raised busy yet, so the wait ends immediately, and the following EVENT_WRITE fires the fence before the kernel ran. The CPU then reads results that are not there yet. The symptom only appears when WAIT_FOR_IDLE directly follows DISPATCH; the test needs exactly that sequence with a busy model that rises late.

**Q6. What breaks with `BUG_IRQ_BEFORE_ACK`?**
The interrupt fires when the write is *accepted* (`mreq_ready`), not when it is acknowledged. A fast CPU that reads the fence address on the interrupt can see the old value. In simulation, the symptom shows up only when the memory path is slow. A checker that the fence is in memory at the time of `irq` catches it.

**Q7. What breaks with `BUG_STRB`?**
The strobe uses `arg0[3:2]` instead of `arg0[4:2]`, so only words 0-3 of a line can be selected. A fence at an address in the upper half of a 32-byte line (byte offset 16 to 31) writes the wrong word, 16 bytes lower. The fence never appears where the CPU looks, so the CPU waits forever. Tests must use fence addresses with bit 4 set.

**Q8. What if fences went through the L2 and we flushed the L2 on every EVENT_WRITE?**
Then the SQE would issue a flush, wait for it, and then write. Fences become much slower (a full flush writes back every dirty line), but they would be ordered with the kernel's own data writes, which also live in the L2. In our design the driver puts an explicit L2 flush (register 0x203) and WAIT_FOR_IDLE before the fence when it needs kernel data visible. The testbench would check that dirty data reaches DRAM before the fence value.

**Q9. What if operations took more than two arguments?**
`arg0` and `arg1` are the only storage; extra payload dwords are ignored. A 3D dispatch (x, y, z workgroup counts) would need `arg2`, a wider `n_args` counter, and a dispatcher with a 3D interface. The testbench would add packets with more arguments and check that each one lands in the right place.
