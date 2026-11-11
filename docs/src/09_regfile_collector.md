# 09 Register file and operand collector

## What this block is, in plain words

Each thread has 16 registers; a sub-core holds 4 warps x 8 threads, so 512 registers of 32 bits. Reading them all at once would need a huge memory with many ports, so real GPUs split the register file into **banks**, each able to do one read and one write per cycle. The **operand collector** takes an issued instruction, reads its operands from the banks (taking an extra cycle when two operands are in the same bank: a **bank conflict**), and then hands the instruction with its values to the right execution unit. Results come back through the write ports.

## Where it sits and who talks to it

| Who | Talks to | For what | Signals |
|---|---|---|---|
| Warp scheduler | collector | the issued instruction, with the warp's active mask | `is_valid`, `is_ready`, `is_warp`, `is_instr`, `is_pc`, `is_mask` |
| Collector | ALU / SFU / LSU / barrier | instruction plus 8 lanes of operand A and B | `ex_valid`, `ex_unit`, `ex_ready[4]`, `ex_a`, `ex_b`, ... |
| ALU, SFU, LSU | register file | results (three write ports) | `wb_valid[3]`, `wb_ready[3]`, `wb_warp`, `wb_rd`, `wb_mask`, `wb_data` |
| Launch | register file | clear the registers of new warps | `wl_mask` |

## Architecture and RTL decisions

| Decision | Why |
|---|---|
| 4 banks; register r of warp w in bank (r + w) % 4 | The same register of different warps falls in different banks, so warps running the same code do not all hit one bank. |
| Operand A = rs1; operand B = rs2, or rd for stores and branches | ST and BEQ/BNE need a third register (the data or the second compare value); reusing the rd field keeps the encoding at 32 bits and the collector at two reads. |
| One collector entry; reads in the cycle after acceptance; a same-bank pair takes two cycles | Simple, and the exact timing is checkable (`BUG_BANK_CONFLICT` reads both from one bank in one cycle). |
| A new instruction is accepted in the same cycle the current one is dispatched | No bubble between back-to-back instructions. |
| Write ports: per bank, port 0 (ALU) beats 1 (SFU) beats 2 (LSU) | The ALU result is the shortest-lived; fixed priority is simple and the checker knows the exact winner. |
| Writes only change lanes in the mask | Divergent code must not overwrite inactive lanes' registers (`BUG_WRITE_ALL_LANES`). |
| r0 reads 0 and is never written; registers start at 0 on launch | Software convention and a clean starting state for every warp. |

## Verification decisions and why

| Decision | Why |
|---|---|
| The checker models the whole register file | Every operand value can be predicted exactly. |
| Drivers obey the scoreboard's rules (no read of a register with a write in flight; no write to a register the collector is reading) | That is the contract the real scheduler guarantees; without it, read/write order would be undefined. |
| Exact dispatch cycle checked (accept + 2, or + 3 with a bank conflict) | Catches extra or missing cycles in the collector, which data checks miss. |
| Write-port grants checked against the priority rule every cycle | A dropped or mis-granted write is caught where it happens. |

**Coverage (14 bins).** Each unit; bank conflict; no operands; r0 operand; same-bank write collision; three writes in one cycle; partial mask; write to r0; launch clear; execution backpressure; back-to-back issue. (These bins first showed 0 hits because Verilator mishandles `$sformatf("%s", cond ? "alu" : "barrier")`; the sampling was rewritten with `case`.)

**Assertions.** One read per bank per cycle (white box), dispatched instruction held until taken, no X.

## Results

| Item | Result |
|---|---|
| Regression | 4 tests x 3 seeds = 12 runs, all PASS (8,797 dispatches and 26,880 writes in one random run) |
| Merged coverage | 100% (14 of 14) |
| `BUG_WRITE_ALL_LANES` | caught (32,254 operand mismatches: inactive lanes overwritten) |
| `BUG_BANK_CONFLICT` | caught by the exact-cycle check and the one-read-per-bank assertion |

# Teaching section: the register file and operand collector in context

## The block and its pins

```pins
block: Register file + collector | regfile_collector.sv · 4 warps x 16 regs x 8 lanes x 32 bits · 4 banks · 1 collector entry · 3 write ports
in: wl_mask | subcore launch logic | clear all registers of these warps to 0
in: is_valid / is_ready | warp scheduler | handshake: an instruction is issued / the collector can take it
in: is_warp, is_instr, is_pc, is_mask | warp scheduler (mask from simt_stack) | which warp, instruction, PC, and active lanes
in: wb_valid[3] / wb_ready[3] | ALU (0), SFU (1), LSU (2) | handshake: a result is offered / the bank port is free this cycle
in: wb_warp, wb_rd, wb_mask, wb_data[8] (x3) | ALU, SFU, LSU | the register to write, which lanes, and the 8 values
out: ex_valid, ex_unit / ex_ready[4] | ALU, SFU, LSU, barrier | handshake: operands are ready for unit 0..3 / that unit can take it
out: ex_warp, ex_instr, ex_pc, ex_mask | execution units | the instruction and its context
out: ex_a[8], ex_b[8] | execution units | operand A (rs1) and operand B (rs2, or rd for stores and branches) per lane
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the sub-core pipeline

```hflow
Warp scheduler | issues instr -is-> Operand collector | reads rs1, rs2 x 8 lanes | you -ex-> ALU / SFU / LSU / BAR | execute -wb-> Register file | writes rd | you
```

This block is two pipeline stages in one module: the **register read / operand collect** stage on the way in, and the **write-back** stage on the way out.

| Stage | What happens here | Time |
|---|---|---|
| Operand collect | Read operand A and B for 8 lanes from the banks | 1 cycle, or 2 when A and B are in the same bank |
| Dispatch | Pick the unit with `unit_of(opcode)`; wait for that unit's ready | as long as the unit is busy |
| Write-back | Up to 3 results per cycle, one per bank | 1 cycle unless two results want the same bank |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Warp scheduler (07) | is_* | Hands over each issued instruction. `is_ready` low means the collector entry is still full: the scheduler holds its request. |
| SIMT stack (08), via subcore | is_mask | The active-lane mask of the warp, attached at issue so lanes switched off by divergence are not written. |
| ALU (10) | ex_* (unit 0), wb port 0 | Integer ops and branches. Port 0 has highest write priority. |
| SFU (11) | ex_* (unit 1), wb port 1 | DIV, REM, ISQRT. |
| LSU (13) | ex_* (unit 2), wb port 2 | LD/ST/LDS/STS: `ex_a` is the address base, `ex_b` the store data. |
| Barrier (12) | ex_valid with ex_unit = 3 | BAR uses the collector only to be routed; unit 3 is always ready. |
| Warp scheduler (07) | wb fire (`wbv & wbr`) | Snooped to clear scoreboard bits, only for writes that really happened. |

## Design details

- **Storage shape.** Each warp has 16 registers, each register holds 8 lanes of 32 bits: so one register is 256 bits wide. That is 512 bytes per warp and 2 KB for all 4 warps. One read gives all 8 lanes at once, because every lane needs the same register number.
- **Banking.** Instead of one big memory with many ports, the registers are split into 4 banks, each with 1 read port and 1 write port. Register r of warp w lives in bank (r + w) mod 4. Adding the warp number spreads "r1 of every warp" across different banks, so different warps do not all collide on the same bank.
- **Bank conflicts on read.** If A and B of one instruction live in the same bank (for example r1 and r5, both bank 1 for warp 0), the bank can only give one per cycle: A is read first, B one cycle later. Otherwise both are read in the same cycle.
- **One collector entry.** The collector holds one instruction. It accepts a new one when empty, or in the same cycle the old one leaves (`is_ready = !occ || ex_fire`), so in the good case there is no bubble.
- **Write-back arbitration.** Three units can finish in the same cycle. Per bank, the lowest-numbered port wins (ALU before SFU before LSU); losers keep `wb_valid` up and retry. A write only changes the lanes in its mask, and r0 is never written and always reads 0.
- **Read before write.** Reads in a cycle see the values from before that cycle's writes. That is safe because the scheduler's scoreboard does not issue an instruction whose source is still pending.
- **Launch clears registers.** `wl_mask` zeroes every register of a relaunched warp, so a new workgroup never sees data from the previous one.

## Questions: what if we did it differently?

**Q1. What if we used one multiported register file instead of banks?**
A 2-read, 3-write port memory serves any combination without conflicts. But the area of a register file grows roughly with the square of the number of ports, and real GPU register files are huge (hundreds of KB per SM). Banking with single-ported SRAM banks is how real GPUs keep area down. We would lose the 2-cycle bank-conflict case and the write arbitration, but pay for it in area and power. The bench's "one read per bank per cycle" assertion would disappear.

**Q2. What if there were several collector entries?**
Real GPUs have several collector units. While one instruction waits for a bank or for a busy unit (say the SFU for 32 cycles), others keep reading their operands and go to free units. That is out-of-order dispatch across warps and removes the head-of-line blocking we have today: a DIV waiting for the SFU blocks everything behind it. The cost is more operand storage (each entry holds 2 x 8 x 32 bits) and an arbiter to choose which entry reads which bank each cycle. The bench would need to accept dispatches in a different order than issue.

**Q3. What about a register cache or operand reuse?**
A small cache of recently read operands (NVIDIA calls one form of this "operand reuse") lets back-to-back instructions using the same register skip the bank read. That saves energy and avoids conflicts. It needs tags per cached operand and invalidation on write. For us the gain would be small, but it is a common energy trick.

**Q4. What if the bank mapping were just r mod 4, without adding the warp?**
Correctness would not change. But common registers (r1, r2 used for thread id and address) of every warp would all sit in the same bank, so write-backs from different warps landing in the same cycle would collide more often. The (r + w) swizzle is a cheap way to spread the load. An XOR swizzle (r XOR w) does the same job.

**Q5. What if write-back priority were round-robin instead of fixed?**
With fixed priority, the LSU can lose to the ALU repeatedly when both target the same bank. It only loses when both target the same bank in the same cycle, which needs a particular mix of warps and registers, so in practice it waits a cycle or two; but in principle a steady stream of ALU results to that bank could keep it waiting. Round-robin costs a pointer per bank and makes the cycle-exact reference model a little harder.

**Q6. Why read operand B from rd for stores and branches?**
A store needs a base address and data; a BEQ needs two values to compare; neither writes a register. Reusing the rd field as a second source keeps the instruction format small. The collector only needs `src_b()` to pick the right field, and only two read ports are ever needed.

**Q7. What does `BUG_BANK_CONFLICT` break?**
Operand B is read in the same cycle as A even when they share a bank. Functionally the model still gives the right value (it is just an array in simulation), so results look correct. The bug is that real single-ported SRAM banks could not do that. The bench catches it with an assertion that each bank is read at most once per cycle and with a cycle-exact check of when the instruction should leave.

**Q8. What does `BUG_WRITE_ALL_LANES` break?**
Write-back ignores `wb_mask` and writes all 8 lanes. Lanes that were inactive because of divergence (or that had exited) get their registers overwritten with garbage from the inactive lanes' datapath. The program then breaks later, when those lanes reconverge and read their registers. The bench found tens of thousands of operand mismatches.
