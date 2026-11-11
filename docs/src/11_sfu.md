# 11 SFU (special function unit)

## What this block is, in plain words

Division and square root take many steps; doing them in one cycle would need a huge circuit. The SFU does them over many cycles instead: one bit of the answer per cycle for division (32 cycles), two bits per cycle for the integer square root (16 cycles), for all 8 lanes in parallel. While it works it says "not ready", so the scheduler simply runs other warps.

| Instruction | Result | Latency |
|---|---|---|
| DIV | a / b unsigned; b = 0 gives 0xFFFFFFFF | 32 cycles + 1 |
| REM | a % b unsigned; b = 0 gives a | 32 cycles + 1 |
| ISQRT | floor(sqrt(a)) | 16 cycles + 1 |

## RTL decisions and why

| Decision | Why |
|---|---|
| Restoring division, 1 quotient bit per cycle | The simplest correct divider; latency is fixed, which keeps the scoreboard simple. |
| Divide by zero defined (all ones, remainder = dividend), like RISC-V | No exception path in a GPU. These values come out of the restoring divider by themselves; the planted bug `BUG_DIV0` "special-cases" them to 0, a realistic mistake. |
| Digit-by-digit square root, fixed 16 steps | Exact for all 32-bit inputs (`BUG_ISQRT_ITER` does 15 steps). |
| One instruction at a time; not ready while busy or while the result waits for the register file | No queue needed; a new op cannot overwrite a running one (`BUG_BUSY_ACCEPT`). |

## Waveform (from the simulation)

Smoke test: REM (opcode 0x11) is accepted in cycle 2; from cycle 3 the counter runs 32, 31, ... and lane 0's partial remainder builds up 1, 2, 4, 9, 18, 36 ... one bit per cycle.

```wave
clk     | ppppppp
ex_valid| 1111111
ex_ready| 1000000
run     | 0111111
cnt     | x======| 32 31 30 29 28 27
```

## Verification decisions and why

| Decision | Why |
|---|---|
| Reference uses SV's own `/` and `%`, and finds the square root by checking r^2 <= a < (r+1)^2 in 64-bit math | Independent of the RTL algorithm. |
| Operand classes: random, corners (0, 1, 2, 3, max, 0x80000000), small divisors including 0, values around perfect squares (s^2 - 1, s^2, s^2 + 1) | Each class targets a different failure (divide by zero, off-by-one in the root, overflow). |
| Exact latency checked | The fixed latency is a promise to the rest of the sub-core. |

**Coverage (14 bins).** Each op; divide and remainder by zero; a < b; a = max; perfect square, square minus 1, zero and max for ISQRT; partial mask; backpressure; back-to-back operations.

## Results

| Item | Result |
|---|---|
| Regression | 3 tests x 3 seeds = 9 runs, all PASS; 2,000 operations x 8 lanes in `sfu_rand_test` |
| Merged coverage | 100% (14 of 14) |
| `BUG_DIV0` / `BUG_ISQRT_ITER` / `BUG_BUSY_ACCEPT` | all caught (374, 4,819 and 14,283 errors) |

# Teaching section: the SFU in context

## The block and its pins

```pins
block: SFU | sfu.sv · 8 lanes · DIV/REM 32 cycles · ISQRT 16 cycles · one instruction at a time
in: ex_valid / ex_ready | regfile_collector | handshake: a DIV/REM/ISQRT is offered / the SFU is free
in: ex_warp, ex_instr, ex_mask | regfile_collector | which warp, the instruction (opcode and rd), which lanes are active
in: ex_a[8], ex_b[8] | regfile_collector | dividend and divisor (or the ISQRT input in ex_a) for each lane
in: wb_ready | regfile_collector | the register file accepted the result on write port 1
out: wb_valid, wb_warp, wb_rd | regfile_collector | a result for register rd of this warp
out: wb_mask, wb_data[8] | regfile_collector | which lanes to write, and their 8 values
out: busy | subcore | working or holding a result: the workgroup is not finished yet
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the sub-core pipeline

```hflow
Warp scheduler | issues DIV -instr-> Operand collector | reads a, b x 8 lanes -a, b-> SFU | iterate 16 or 32 cycles | you -result-> Register file | writes rd
```

The SFU is a second **execute stage**, beside the ALU, for slow operations. The collector sends it every instruction whose `unit_of(opcode)` is the SFU (`ex_unit = 1`).

| Opcode | Result | Cycles of iteration | Divide by zero |
|---|---|---|---|
| DIV | a / b, unsigned | 32 | 0xFFFFFFFF |
| REM | a % b, unsigned | 32 | a |
| ISQRT | floor(sqrt(a)), unsigned | 16 | not applicable |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Operand collector (09) | ex_* in (unit 1), wb_* out (write port 1) | Sends the instruction with operands; takes the result back. While the SFU is busy, a DIV waits in the collector. |
| Warp scheduler (07) | indirectly, via wb fire | The scoreboard keeps `rd` pending for the whole 32 cycles; dependent instructions of that warp wait, other warps keep running. |
| Sub-core (15) | busy | The workgroup only finishes (`wg_done`) when every warp has exited **and** the SFU has no result left to write. |
| Kernels | — | Integer division and modulo (for example turning a flat index into row and column) and square roots. |

## Design details

- **Restoring division, one bit per cycle.** The divider is the schoolbook long division in binary. Each cycle it shifts the next bit of the dividend into a 33-bit partial remainder, compares it with the divisor, subtracts if it fits and shifts a 1 into the quotient, or a 0 if it does not. After 32 cycles the quotient register holds a / b and the remainder register holds a % b. DIV and REM use the same hardware and differ only in which register is sent back.
- **Divide by zero for free.** With b = 0, "does 0 fit?" is always yes, so every quotient bit is 1 (0xFFFFFFFF) and the remainder ends up equal to a. These are the same answers RISC-V defines, so no special case is needed.
- **Digit-by-digit square root.** ISQRT uses the classic shift-and-subtract square root: a "one" bit starts at 0x40000000 and moves right by 2 every cycle, so 16 cycles cover all 32 input bits (2 bits per result bit).
- **All 8 lanes in lockstep.** There is one counter and one control FSM, but 8 copies of the datapath (remainder, quotient, divisor, root registers). Every lane finishes at the same cycle.
- **One instruction at a time.** `ex_ready = !run && (!wb_valid || wb_ready)`: the SFU accepts only when it is not iterating and has no unsent result. This avoids overwriting a result that the register file has not yet taken.
- **Why multi-cycle at all.** A full 32-bit combinational divider is a chain of 32 subtract-and-compare stages: huge, and by far the slowest path in the design. Doing one stage per cycle reuses one small stage 32 times. Division is rare in GPU code, so the slowness is acceptable.

## Questions: what if we did it differently?

**Q1. What if the divider were pipelined instead of iterative?**
Unroll the 32 steps into 32 pipeline stages, each with its own registers. Latency stays 32 cycles, but a new DIV could start every cycle: throughput goes from one per 32 cycles to one per cycle. The cost is about 32 times the datapath area, times 8 lanes. The scoreboard is unaffected (it already handles long latency), but the bench would have to track several DIVs in flight and check that results come back in order.

**Q2. What about SRT division (radix 4)?**
SRT division produces 2 quotient bits per cycle using a small lookup table and a redundant remainder, so the subtraction need not be fully resolved every step. DIV would drop to about 16 cycles, plus a final correction step. The logic is harder to verify: the famous Pentium FDIV bug was a missing entry in an SRT table. The reference model stays the same (a / b), but the bench should add directed tests near table boundaries.

**Q3. What about Newton-Raphson or Goldschmidt division?**
These compute 1/b by repeated multiply-and-subtract; each iteration doubles the number of correct bits, then a / b = a x (1/b). They reuse a multiplier (which the ALU already has) and converge in a few iterations from a small seed table, which is why GPUs use them for floating point. For exact integer results a correction step is needed, because the reciprocal is rounded. Verification must check the corner cases where rounding gives an off-by-one quotient.

**Q4. What if lanes could finish at different times (early termination)?**
A divider could stop early when the dividend has many leading zeros. But all 8 lanes share one counter and write back together, so the slowest lane decides anyway. Early exit only helps if every lane is small, and it makes the latency data-dependent, which the bench would then have to model per operation.

**Q5. What if the SFU accepted a new instruction while the old result waits for write-back?**
That is what `BUG_BUSY_ACCEPT` does (see Q8): unsafe with a single result register. Doing it properly needs a second result buffer (a skid buffer) so the new operation can start while the old result waits. That raises throughput slightly when the register file port is busy.

**Q6. What about floating point special functions (sin, exp, rcp)?**
Real SFUs compute these with a lookup table plus quadratic interpolation, 4 to 8 values per cycle across a warp, and are shared by many lanes (a warp of 32 is passed through a 4-wide SFU over several cycles). Adding them here would mean an FP format, a table ROM and a new reference model with an error tolerance (ULP) instead of exact compare.

**Q7. What does `BUG_DIV0` change?**
It returns 0 for divide by zero instead of all ones. That disagrees with the ISA spec (which follows RISC-V). Any kernel that tests for "division gave all ones" to detect b = 0 would silently go wrong. Directed b = 0 tests caught it.

**Q8. What does `BUG_BUSY_ACCEPT` break?**
`ex_ready` ignores a waiting result. If the register file has not yet accepted the previous result (write port 1 lost arbitration to the ALU) and a new DIV arrives, the new operation overwrites `wb_warp`, `wb_rd` and the iteration registers. The old result is lost or written to the wrong register, and that warp's scoreboard bit for the lost register never clears, so the warp can hang. A bench that holds `wb_ready` low at random times finds it quickly.

**Q9. What does `BUG_ISQRT_ITER` break?**
ISQRT runs 15 iterations instead of 16. The last step, which both decides the lowest result bit and does the final shift of the root register into place, never happens, so the value read out is wrong for most inputs. Random inputs catch it in the first few operations; it is a typical loop-bound off-by-one.
