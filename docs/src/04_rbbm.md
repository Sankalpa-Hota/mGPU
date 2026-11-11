# 04 RBBM (register bus, interrupts, hang detect, performance counters)

## What this block is, in plain words

The CPU needs a small "control panel" on the GPU: a few switches it can set (where the command ring is, how far it has written), a few lights it can read (how far the GPU has read, which blocks are busy), a doorbell the GPU can ring (the interrupt), and a few meters (performance counters). The **RBBM** is that control panel. The CPU reaches it over **APB**, a simple register bus.

It also has a watchdog. If the GPU says it is busy but makes no progress for too long, the RBBM raises a **hang** interrupt so the driver can reset the GPU instead of freezing the computer.

## Where it sits and who talks to it

```hflow
CPU -APB register reads/writes-> RBBM -ring base, WPTR-> CP ring fetch
CP ring fetch -RPTR-> RBBM
SQE and decoder -fence, error flags-> RBBM -interrupt-> CPU
All blocks -busy, progress, perf events-> RBBM
```

| Who | Talks to | For what | Signals |
|---|---|---|---|
| CPU | RBBM | read and write registers | APB: `psel`, `penable`, `pwrite`, `paddr[11:0]`, `pwdata`, `prdata`, `pready`, `pslverr` |
| RBBM | CP ring fetch | where the ring is, how far the CPU wrote | `ring_base`, `ring_wptr` |
| CP ring fetch | RBBM | how far the GPU read | `ring_rptr` |
| SQE | RBBM | fence written, job done (pulse); illegal opcode (sticky) | `ev_fence`, `ev_bad_op` |
| Packet decoder | RBBM | illegal packet (sticky) | `ev_bad_pkt` |
| All blocks | RBBM | busy bits, "progress made" pulse, performance events | `busy_in[7:0]`, `progress`, `perf_ev[15:0]` |
| RBBM | CPU | interrupt line | `irq` |
| RBBM | whole GPU | soft reset | `soft_reset` (one-cycle pulse) |

## APB in one paragraph

Each transfer takes two cycles. In the **setup** cycle the CPU raises `psel` and puts the address, direction and write data on the bus. In the **access** cycle it raises `penable`; the transfer completes when the slave raises `pready` (RBBM always does, so every access is exactly two cycles). On a read the slave drives `prdata` in the access cycle. `pslverr` in the access cycle says "this access was illegal".

```wave
clk     | pppppp
psel    | 011110
penable | 001010
pwrite  | x1.0.x
paddr   | x=.=.x| 014 010
pwdata  | x=.xxx| F
prdata  | xxxx=x| 5
```

Illustration: a write of 0xF to IRQ_MASK (0x014), then a read of IRQ_STATUS (0x010) returning 5.

## Register map

| Offset | Name | Access | Meaning |
|---|---|---|---|
| 0x000 | ID | RO | `0x6D475055` ("mGPU"); software checks it to know it found the right device |
| 0x004 | RING_BASE | RW | byte address of the ring; bits [4:0] are always 0 (line aligned) |
| 0x008 | RING_WPTR | RW | write pointer, sent to the CP |
| 0x00C | RING_RPTR | RO | read pointer, from the CP |
| 0x010 | IRQ_STATUS | W1C | bit 0 fence, bit 1 bad packet, bit 2 bad op, bit 3 hang. Writing a 1 clears that bit; writing 0 leaves it |
| 0x014 | IRQ_MASK | RW | which status bits drive the interrupt line |
| 0x018 | BUSY_STATUS | RO | live busy bits |
| 0x01C | HANG_TIMEOUT | RW | cycles of "busy and no progress" before the hang bit is set; 0 turns the watchdog off |
| 0x020 | SOFT_RESET | WO | writing bit 0 = 1 sends a one-cycle reset pulse; reads 0 |
| 0x040 + 8i | PERF_SEL[i] | RW | which of the 16 events counter i counts (i = 0..3) |
| 0x044 + 8i | PERF_CNT[i] | RW | the count; +1 every cycle the selected event is high; software may write it (usually to clear it) |

Any other address, and any write to a read-only register, completes with `pslverr = 1` and changes nothing.

## Architecture

```tree
rbbm | control panel | root
  APB decode | address match, read mux, SLVERR for unknown / read-only | comp
  Ring registers | RING_BASE, RING_WPTR out; RING_RPTR in | comp
  IRQ logic | status set by events, cleared by W1C, masked into irq | comp
  Edge detectors | turn the sticky error flags into one-time events | comp
  Hang watchdog | counts busy cycles without progress | comp
  Perf counters x4 | event select mux + 32-bit counter each | comp
```

## RTL decisions and why

| Decision | Why |
|---|---|
| Zero wait states (`pready = 1`) | Every register is a flop or a live input, so data is ready at once. Keeps CPU polling loops fast. |
| SLVERR for unknown addresses and for writes to read-only registers | Silent failure hides driver bugs. With SLVERR the CPU gets a bus error and the driver developer finds the wrong address immediately. (Note: UVM's built-in bit-bash sequence assumes read-only writes are silently ignored, so ID is excluded from it; the SLVERR path is checked by the illegal-access test instead.) |
| IRQ_STATUS is **write-1-to-clear** | The ISR reads the status and writes the same value back. Only the bits it saw are cleared; a new event that arrived in between stays set. With a plain RW register the ISR would have to read-modify-write and could erase an event that came in between. |
| Same cycle: hardware sets a bit and software clears it, **the set wins** | An event must never be lost: the ISR clears what it saw, and the new event shows up as still pending. Planted bug `BUG_W1C_LOSES_SET` does the opposite. |
| Error flags from the decoder and SQE are sticky, so the RBBM interrupts on their **rising edge** | Otherwise the status bit would be set again every cycle and the ISR could never clear it. |
| Watchdog counts only while something is busy **and** nothing progresses; any progress pulse resets it | A long but healthy job (progress pulses keep coming) must never be reported as a hang. Planted bug `BUG_HANG_IGNORES_PROGRESS` reports false hangs. |
| Watchdog restarts after firing | If the hang is ignored (interrupt masked), it fires again every timeout period instead of once. |
| PERF_CNT write wins over an event in the same cycle | When software writes 0 to start a measurement, the counter must really start at 0. Planted bug `BUG_PERF_WRITE_LOST` lets the event win and loses the write. |
| Counters wrap at 2^32 | Software reads twice and subtracts; wrap-around is handled by unsigned subtraction. Saturating counters would break that. |

## Waveform (from the simulation)

IRQ test, cycles 9 to 16 (column 0 is cycle 9). The ISR reads IRQ_STATUS in cycle 10 and gets 1 (a fence). It writes 1 back in cycles 11-12 (W1C), so status becomes 0 and `irq` drops in cycle 13. It reads again in cycle 14 (0). In that same cycle the decoder's `bad_pkt` flag rises; the RBBM turns the rising edge into status bit 1 (value 2) and `irq` goes high again in cycle 15.

```wave
clk        | pppppppp
psel       | 11111111
penable    | 01010101
pwrite     | 0.1.0.1.
prdata     | x=xxx=xx| 1 0
ev_fence   | 01000000
ev_bad_pkt | 00000111
IRQ_STATUS | =...=.=.| 1 0 2
irq        | 11110011
```

## RTL file

| File | What is inside |
|---|---|
| `rtl/04_rbbm/rbbm.sv` | APB decode, registers, IRQ logic, watchdog, counters; planted bugs `BUG_W1C_LOSES_SET`, `BUG_HANG_IGNORES_PROGRESS`, `BUG_PERF_WRITE_LOST` |

## Testbench architecture

This is the first block with a **register model** (UVM RAL). Two checkers work side by side, each on what it is good at.

```hflow
RAL sequences -register names-> Register model -APB items (adapter)-> APB agent -> DUT
Raw APB sequence -illegal addresses-> APB agent
HW driver -events, busy, perf-> DUT
```

```hflow
APB monitor -observed accesses-> Predictor -update mirror-> Register model
Pins every cycle -> Cycle-accurate reference model -checks reads and outputs-> errors
```

| File | Plain-words role |
|---|---|
| `rbbm_interface.sv` | the wires |
| `rbbm_config.sv` | event rates; `hw_quiet` freezes the hardware side for pure register tests |
| `rbbm_transactions.sv` | `apb_item`: address, direction, write data, read data, slverr |
| `rbbm_apb_agent.sv` | APB driver (setup then access), monitor, agent |
| `rbbm_reg_model.sv` | the RAL model: one class per register, the address map, and the adapter that turns register operations into APB items and back |
| `rbbm_hw_driver.sv` | plays the rest of the GPU: RPTR moves, fence pulses, error flags, busy bits, progress pulses, 16 perf events |
| `rbbm_reference_model.sv` | cycle-accurate model of every register; checks every read, every slverr and every output, every cycle; holds the 35 coverage bins |
| `rbbm_sequences.sv` | raw APB traffic (including illegal), ISR loop, watchdog sequence, perf counter sequence, static register write-and-mirror sequence |
| `rbbm_env.sv`, `rbbm_tests.sv`, `rbbm_pkg.sv`, `rbbm_assertions.sv`, `rbbm_tb_top.sv`, `Makefile` | wiring (including the RAL predictor), eight tests, package, APB protocol assertions, top |

## Verification decisions and why

**What we check, in one sentence.** Every register reads its exact value in every cycle, every write lands only where it should, illegal accesses are refused, no interrupt event is ever lost, the watchdog fires exactly when it should and never otherwise, and counters count exactly.

| Decision | Why |
|---|---|
| Use RAL for **static** registers (RING_BASE, RING_WPTR, IRQ_MASK, HANG_TIMEOUT, PERF_SEL, ID) | These change only when software writes them, so the RAL mirror predicts them perfectly. `mirror(UVM_CHECK)` gives a free check, and the built-in reset and bit-bash sequences test every bit with no extra code. Sequences written with register names survive address-map changes. |
| Mark IRQ_STATUS, RING_RPTR, BUSY_STATUS and PERF_CNT as **volatile** and do not check them through the mirror | Hardware changes them between the write and the read. A mirror check on them would fail randomly (a false error) or be switched off (no check). |
| Check volatile registers with a **cycle-accurate reference model** | The only correct expected value for "IRQ_STATUS read in cycle 1234" is the value built from every event and every W1C up to cycle 1233. The model rebuilds exactly that from the pins. |
| The model checks the outputs (`irq`, `ring_base`, `ring_wptr`, `soft_reset`) every cycle, not only on reads | The interrupt line matters even when nobody reads the register: a stuck or missing `irq` is the bug software actually sees. |
| A separate raw APB sequence sends illegal accesses | RAL refuses to generate accesses to addresses that are not in the map, and writes to RO registers. Those are exactly the accesses that must return SLVERR. |
| An explicit predictor, auto-predict off | The mirror is updated from what the monitor saw on the bus, so accesses made outside RAL (the raw sequence) also update it, and a driver bug cannot fake a correct mirror. |
| `hw_quiet` for the reset and bit-bash tests | Those built-in sequences assume nothing else changes registers while they run. |
| ISR-style sequence reads status and writes back what it read | That is how a real driver uses W1C. Random extra W1C values also clear bits that were not read, to test that W1C only clears ones. |
| High event rates in the IRQ test | A W1C and a hardware event on the same bit in the same cycle is the dangerous corner; it only happens often enough when events are frequent. |

**Why these coverage bins (35).**

| Bins | Why |
|---|---|
| read of every register kind, write of every writable register | every decode path |
| slverr unmapped, slverr write to read-only | both error causes |
| each interrupt source fired, masked pending, irq line high | every IRQ path and the mask |
| W1C clear, **W1C in the same cycle as an event** | the lost-event corner |
| hang fired, hang counter reset by progress | the watchdog firing and *not* firing |
| each of the 4 counters counted, **counter write in the same cycle as an event** | the lost-write corner |

**Why these assertions.**

| Assertion | Rule | Why |
|---|---|---|
| `a_setup_first`, `a_stable_in_access`, `a_penable_drops` | APB master rules | checks the testbench driver, so its bugs are not blamed on the DUT |
| `a_slverr_only_in_access` | SLVERR only in the access phase | APB slave rule |
| `a_rdata_known` | no X on PRDATA during a read | an X read could pass a lenient compare |
| `a_soft_reset_pulse` | soft reset is one cycle | a long pulse would hold the GPU in reset |

## Tests and why each exists

| Test | Purpose |
|---|---|
| `rbbm_reset_value_test` | RAL `uvm_reg_hw_reset_seq`: every register reads its reset value |
| `rbbm_bit_bash_test` | RAL `uvm_reg_bit_bash_seq`: every bit of every static register can be set and cleared alone |
| `rbbm_static_reg_test` | random writes and `mirror(UVM_CHECK)` of static registers while hardware runs |
| `rbbm_illegal_access_test` | 400 raw accesses including unmapped addresses and RO writes |
| `rbbm_irq_test` | ISR loop with frequent events |
| `rbbm_hang_test` | busy stays high, progress is rare; random timeouts |
| `rbbm_perf_test` | counter selection, reads and writes while events are frequent |
| `rbbm_rand_test` | all of the above mixed |

## Results

| Item | Result |
|---|---|
| Regression | 8 tests x 3 seeds = 24 runs, all PASS |
| APB accesses checked | 9 to 1,115 reads per run by the cycle model, plus RAL mirror checks and the built-in reset and bit-bash sequences |
| Merged functional coverage | 100% (35 of 35 bins) |
| `BUG_W1C_LOSES_SET` | **caught**: `irq=0 but status=1 mask=7` (a fence arrived in the same cycle as the W1C and was erased) |
| `BUG_HANG_IGNORES_PROGRESS` | **caught**: `irq=1 but status=0 mask=8` (a false hang interrupt during a healthy job) |
| `BUG_PERF_WRITE_LOST` | **caught**: `read PERF_CNT (04c) = 00000005, expected fffffff1` |
| Found during bring-up | testbench: the register model was never `reset()`, so its mirror started at 0 instead of the reset values; reference model: SOFT_RESET must read 0; spec vs UVM library: bit-bash expects silent RO writes, our RBBM returns SLVERR (ID excluded from bit-bash on purpose) |

## What is not verified here

- Multi-master APB or APB wait states (the slave never inserts them).
- What the rest of the GPU does on `soft_reset`; that is checked at full-chip level.

# Teaching section: the RBBM in context

## The block and its pins

```pins
block: RBBM | rbbm.sv · APB slave, zero wait states · 4 IRQ sources · 4 perf counters
in: psel, penable, pwrite, paddr[11:0], pwdata | CPU (testbench APB master) | one register access
in: ring_rptr | cp_ring_fetch | how far the CP has read the ring
in: ev_fence, ev_bad_pkt, ev_bad_op | cp_sqe, cp_packet_decoder | interrupt sources: fence pulse, sticky error flags
in: busy_in[7:0], progress | busy and progress logic in mgpu_top | for BUSY_STATUS and the hang detector
in: perf_ev[15:0] | events from SMs, MMU, DRAM, CP, GMU | what the performance counters can count
out: prdata, pready, pslverr | CPU | read data, always ready, error for bad offset or write to read-only
out: ring_base, ring_wptr | cp_ring_fetch | where the ring is and how far the CPU has written
out: irq | CPU interrupt line | any unmasked IRQ_STATUS bit
out: soft_reset | mgpu_top reset logic | one-cycle pulse that resets everything except the RBBM
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the system

```hflow
CPU | driver software -APB-> RBBM | registers, IRQ, hang, perf | you -wptr-> Ring fetch | reads commands -dwords-> CP decoder and SQE | execute -irq-> CPU | interrupt handler
```

The RBBM is the **CPU's only direct door into the GPU**. Everything else happens through memory (the ring and the fences). The CPU uses the RBBM for four jobs:

| Job | Registers |
|---|---|
| Tell the CP about work | RING_BASE, RING_WPTR, read back RING_RPTR |
| Get told when work finishes or fails | IRQ_STATUS (W1C), IRQ_MASK, the `irq` pin |
| Watch health | BUSY_STATUS, HANG_TIMEOUT, SOFT_RESET |
| Measure performance | PERF_SEL[0..3], PERF_CNT[0..3] |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| CPU driver (the testbench) | APB pins, irq | Programs the ring, acknowledges interrupts, sets the watchdog, reads counters. |
| Ring fetch (02) | ring_base, ring_wptr out; ring_rptr in | The doorbell: a WPTR write starts the fetch. RPTR goes back to the CPU. |
| SQE (03) | ev_fence, ev_bad_op | Fence interrupt and unknown-opcode error. |
| Packet decoder (01) | ev_bad_pkt | Illegal-header error. |
| mgpu_top | busy_in, progress, perf_ev | Busy bits 0-3, a progress pulse (any finished operation, accepted command dword, or SM instruction issue), and 13 perf events (SM issue, L1 hits, TLB hit, page walk, DRAM row hit and miss, op done, launch, GMU off and wake, command dword). |
| mgpu_top reset | soft_reset | `core_rst_n = rst_n && !soft_reset`: every block except the RBBM itself is reset, so the CPU keeps its register settings and can recover. |

## Design details

- **Zero-wait APB.** `pready` is tied to 1. Reads are combinational from the registers, writes take effect at the end of the access phase (`psel && penable`). Every access takes the minimum two APB cycles.
- **Address decode with errors.** Unknown offsets and writes to read-only registers complete with `pslverr = 1` and change nothing. The driver learns about its own bugs instead of silently writing nowhere.
- **Interrupt status is write-1-to-clear (W1C).** The CPU reads IRQ_STATUS, handles the bits it saw, and writes those same bits back to clear them. Bits that arrive in between are not touched. If a hardware event and a clear of the same bit happen in the same cycle, the event wins: the bit stays set, so no interrupt is ever lost.
- **Edge detection for sticky errors.** `bad_pkt` and `bad_op` stay high once set. The RBBM sets the status bit only on their rising edge (`ev && !ev_q`), so clearing the status bit really clears it rather than being re-set every cycle.
- **Level interrupt output.** `irq = |(IRQ_STATUS & IRQ_MASK)` stays high until the CPU clears the status or masks the source. A level interrupt cannot be missed the way a single-cycle pulse could.
- **Hang detector (watchdog).** A counter runs while anything is busy and nothing makes progress. Any progress pulse, or all blocks idle, resets it. When it reaches HANG_TIMEOUT it sets IRQ_STATUS bit 3. HANG_TIMEOUT = 0 turns it off. "Busy without progress" is a better definition of a hang than "busy for long", because a big kernel can be legitimately busy for millions of cycles.
- **Performance counters.** Each of the 4 counters selects one of 16 events with a 4-bit PERF_SEL and adds 1 on every cycle the event is high. A CPU write to PERF_CNT sets the value, and a write wins over a count in the same cycle, so "write 0" reliably restarts a measurement.

## Questions: what if we did it differently?

**Q1. What if the register port were AXI-Lite instead of APB?**
AXI-Lite has separate read and write channels and can have reads and writes in flight together. It is the usual choice when the port hangs on a fast interconnect. For a handful of control registers, APB is smaller and simpler (one transfer at a time, two cycles each). With AXI-Lite the RBBM would need five valid/ready channels and a response per write. The testbench would swap the APB agent for an AXI-Lite agent and test read/write overlap.

**Q2. What if register accesses had wait states (`pready` low)?**
Wait states are needed when a read must reach into a slow block (for example a register on another clock domain). The RBBM could then expose registers inside other blocks directly. The cost is a slower bus and an FSM for `pready`. The testbench's APB driver already must handle `pready`; the checks would add "no data change while `pready` is low".

**Q3. What if IRQ_STATUS were clear-on-read instead of W1C?**
Clear-on-read saves a write, but a debugger or a second reader that reads the register destroys the status, and an event that arrives between the read and the clear might be lost. W1C lets the CPU clear exactly what it handled. The testbench reference model would change its clear rule and add a test that a read clears the bits.

**Q4. What if the interrupt were a pulse (edge) instead of a level?**
A pulse is easy to generate but can be missed if the interrupt controller is not listening, and two events close together become one pulse. A level stays up until handled, which is why the RBBM keeps a status register. Message-signalled interrupts (MSI, a memory write to the interrupt controller) are a third option used on PCIe; that would need a memory port in the RBBM.

**Q5. What breaks with `BUG_W1C_LOSES_SET`?**
The clear is applied after the set: `(status | set) & ~w1c`. If a new fence arrives in exactly the cycle the CPU clears the previous fence bit, the new event is erased. The CPU then waits forever for an interrupt that came and went. The symptom is rare and timing-dependent; a test must aim a W1C write at the same cycle as an event pulse.

**Q6. What breaks with `BUG_HANG_IGNORES_PROGRESS`?**
The counter is not reset by progress. Any long but healthy kernel that keeps the GPU busy longer than HANG_TIMEOUT cycles raises a false hang interrupt. The test that catches it runs a long busy period with steady progress pulses and checks that bit 3 stays 0.

**Q7. What breaks with `BUG_PERF_WRITE_LOST`?**
A count beats a write in the same cycle. If the CPU writes 0 to a counter whose event is high, the write is lost and the counter continues from its old value. Measurements become wrong whenever the event is busy, for example counting SM issue cycles during a kernel. The test writes the counter while its event is held high.

**Q8. What if we had more performance counters, or 64-bit counters?**
32-bit counters at a few GHz wrap within seconds; 64-bit counters avoid that but need two reads (and a latch so the high and low halves match). More counters mean more PERF_SEL/PERF_CNT pairs and a larger decode. Real GPUs have hundreds of events and dozens of counters. The testbench would extend its reference model and add a wraparound test.

**Q9. What if soft reset also reset the RBBM?**
Then the CPU would lose RING_BASE, IRQ_MASK and the counters, and would need to reprogram everything after recovery. Worse, the `soft_reset` pulse would reset its own source. Keeping the RBBM outside the soft-reset domain is the usual "always-on control block" pattern. The testbench checks that RBBM registers survive a soft reset while everything else returns to its reset state.

**Q10. What if the watchdog reset the GPU automatically instead of interrupting?**
Automatic recovery is faster and works even if the driver is stuck, but the driver never learns what happened, and in-flight work is lost silently. Most real GPUs report the hang (our bit 3) and let the driver decide to reset ("TDR" on Windows). The testbench would check that the reset fires after the timeout and that everything except the RBBM restarts.
