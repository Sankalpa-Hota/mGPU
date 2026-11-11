# 10 ALU

## What this block is, in plain words

The ALU does the everyday arithmetic for all 8 lanes of a warp at once: add, subtract, multiply, logic, shifts, compare, immediates, and reading the special registers that tell each thread who it is (lane, warp, workgroup, global thread id, argument address). It also evaluates branch conditions lane by lane and sends the result to the SIMT stack. Results appear one cycle after the instruction arrives.

## Operations

| Instruction | Result per lane |
|---|---|
| ADD SUB MUL AND OR XOR | a op b (MUL: low 32 bits) |
| SHL / SHR | logical shift by b[4:0] |
| SLT | 1 if a < b as signed numbers, else 0 |
| ADDI / LUI | a + imm / imm << 14 |
| S2R k | k=0 lane, 1 warp in workgroup, 2 workgroup id, 3 global thread id = (wg x warps + warp) x 8 + lane, 4 argument base, else 0 |
| BEQ / BNE | taken lanes where a == b / a != b, sent to the SIMT stack with JMP and EXIT |

## RTL decisions and why

| Decision | Why |
|---|---|
| Shift amount = low 5 bits | Defined behaviour for any amount, like real ISAs (`BUG_SHIFT_AMOUNT` shifts by the full value, giving 0 for 32 and above). |
| SLT signed | Loop counters and comparisons of negative values must work (`BUG_SLT_UNSIGNED`). |
| Global thread id computed from the workgroup context | Kernels index arrays with it; a wrong formula silently makes threads overwrite each other (`BUG_TID`). |
| One output register, ready = output empty or being taken | One cycle latency with full throughput; backpressure from the register file stalls the ALU cleanly. |
| Branches produce a pulse to the SIMT stack, not a writeback | Branches write no register. |

## Verification decisions and why

| Decision | Why |
|---|---|
| The reference model is written from the ISA table with different SV constructs (signed `int` compare, `% 32` shift) | A copy of the RTL expression would repeat its mistakes. |
| Operands biased to 0, 1, -1, 0x7FFFFFFF, 0x80000000, 31, 32, 33 | Overflow, sign and shift boundaries are where ALU bugs live. |
| Exact latency of the first result checked | The rest of the pipeline relies on it. |

**Coverage (34 bins).** Every operation; every special register and undefined ones; thread id with 1 and 4 warps; branches all / none / some lanes; JMP; EXIT; NOP and r0 destination give no writeback; add overflow; signed compare with mixed signs; shifts by 32 or more; partial masks; writeback backpressure.

## Results

| Item | Result |
|---|---|
| Regression | 3 tests x 3 seeds = 9 runs, all PASS (5,000 instructions per random run) |
| Merged coverage | 100% (34 of 34) |
| `BUG_SLT_UNSIGNED` | caught: `result 00000001, expected 00000000` |
| `BUG_SHIFT_AMOUNT` | caught: `result 00000000, expected 8f980000` |
| `BUG_TID` | caught: wrong global thread id |

# Teaching section: the ALU in context

## The block and its pins

```pins
block: ALU | alu.sv · 8 lanes · 1-cycle latency
in: ex_valid / ex_ready | regfile_collector | handshake: an instruction is offered / ALU can take it
in: ex_warp, ex_instr, ex_pc, ex_mask | regfile_collector | which warp, the 32-bit instruction, its PC, which lanes are active
in: ex_a[8], ex_b[8] | regfile_collector | the two operands for each of the 8 lanes
in: ctx_wg_id, ctx_nwarps, ctx_arg | subcore launch registers | workgroup context, only used by S2R
in: wb_ready | regfile_collector | register file can accept the result this cycle
out: wb_valid, wb_warp, wb_rd | regfile_collector | a result for register rd of this warp
out: wb_mask, wb_data[8] | regfile_collector | which lanes to write, and their 8 values
out: br_valid, br_warp, br_pc, br_instr | simt_stack | a branch / JMP / EXIT has been evaluated
out: br_taken[8] | simt_stack | per-lane outcome of BEQ/BNE
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the sub-core pipeline

```hflow
Warp scheduler | picks a ready warp -PC-> I-cache | instruction word -instr-> Operand collector | reads rs1, rs2 x 8 lanes -a, b-> ALU | execute | you -result-> Operand collector | writes rd
```

The ALU is the **execute stage** for every integer and control instruction. The collector routes each instruction to one of four units using `unit_of(opcode)`:

| ex_unit | Unit | Instructions |
|---|---|---|
| 0 | ALU | ADD SUB MUL AND OR XOR SHL SHR SLT ADDI LUI S2R, plus BEQ BNE JMP EXIT (these leave on `br_*` instead of `wb_*`) |
| 1 | SFU | DIV REM ISQRT (multi-cycle) |
| 2 | LSU | LD ST LDS STS |
| 3 | Barrier | BAR (an arrive pulse, no datapath) |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Operand collector (09) | ex_* in, wb_* out | Sends ready instructions with operands; takes the result back and writes the register file. Its scoreboard then clears the `rd` busy bit, so dependent instructions may issue. |
| SIMT stack (08) | br_* out | Gets the per-lane branch result and decides whether the warp splits (some lanes taken), jumps (all lanes), or falls through (none). |
| Warp scheduler (07) | indirectly, via `wb_*` | The scheduler snoops write-backs to clear its own pending-register bits. |
| Sub-core (15) | ctx_* in | Holds each warp's launch context (workgroup id, warp count, argument pointer) so S2R can give each thread its identity. |
| Every kernel | — | Most instructions in vector_add, saxpy and reduction are ALU instructions: address math (`tid*4 + base`), loop counters, compares. |

## Design details

- **Datapath.** The datapath is 8 identical lane slices, each a 32-bit adder/subtractor, a multiplier, logic, a barrel shifter and a comparator, feeding one output mux per lane, selected by the opcode. All lanes share one opcode: that is SIMD, the "single instruction" in SIMT.
- **Inactive lanes still compute.** They compute but are not written (`wb_mask = ex_mask`). Gating the datapath per lane only saves power; masking the write is what keeps the result correct.
- **Output pipeline register.** The result sits in a register, so the ALU has a fixed 1-cycle latency. `ex_ready = !wb_valid || wb_ready` is the standard *pipeline-register ready rule*: accept a new instruction if the register is empty or is being emptied this cycle. That gives full throughput with no bubbles, and a clean stall when the register file can't take a result.
- **Branches.** A branch never writes a register. Its outcome is one bit per lane, so it goes on a separate port (`br_*`) for one cycle. Keeping the two paths apart means the SIMT stack never has to look at the write-back bus.
- **S2R.** Special registers come from context inputs, not the register file. A thread finds out who it is at run time, so one program image runs on every thread.
- **MUL.** MUL keeps only the low 32 bits, like RISC-V `mul`. A real GPU would also have `mulhi`/`IMAD`. We skipped them to keep the ISA small.

## Questions: what if we did it differently?

**Q1. What if the ALU result were combinational (0-cycle) instead of registered?**
Execute and write-back would merge into one stage. Latency drops by 1 cycle, but the critical path becomes collector-mux → 32×32 multiplier → write-back mux → register-file write, and the multiplier alone is the longest path in the sub-core. Clock frequency would fall. Real GPUs go the other way: ALU latency is 4–6 cycles, and they hide it by switching warps.

**Q2. What if MUL were pipelined over 3 cycles while ADD stays at 1?**
This is *variable-latency execution*. Two results could arrive in the same cycle, so you need either a write-back arbiter or a *result shift register*: reserve the write-back slot at issue time, the way the CDC 6600 / scoreboard style did. The scoreboard would also need per-opcode latency. That is what real SMs do: FMA pipe, INT pipe, SFU pipe.

**Q3. Why not handle branches in the scheduler (branch prediction) instead of the ALU → SIMT stack?**
GPUs don't predict branches. With many warps in flight, a stalled warp is replaced by another ready warp, so the branch delay is hidden by *multithreading* rather than speculation. Alternatives and their costs:
- **Static predict-not-taken plus flush:** needs flush logic per warp, which is wasted on a GPU.
- **Branch delay slot (MIPS):** visible in the ISA, and divergence makes it messy.

**Q4. Could we use predication instead of a SIMT stack for if/else?**
Yes. With *predication* (as in ARM, IA-64, and PTX `@p` guards), every instruction carries a predicate register, and lanes with a false predicate don't write. You avoid stack hardware, and short if/else bodies don't diverge. The cost is that both paths always execute, and nested loops with divergent trip counts are hard. Real GPUs use both: the compiler predicates short bodies and uses the stack or convergence barriers for long ones.

**Q5. What breaks if the shift uses the full 32-bit `b` (`BUG_SHIFT_AMOUNT`)?**
Shifting by 32 or more gives 0 instead of `a << (b mod 32)`. Code that builds masks from shift counts would silently differ from the ISA spec. The alternatives:
- **Saturating shifts:** the x86 SIMD style, giving 0 for 32 or more.
- **Masking to 5 bits:** the RISC-V and x86 scalar style, which we chose.

Either is fine if the ISA document says which one. The bug is the hardware and the spec disagreeing.

**Q6. What if SLT were unsigned (`BUG_SLT_UNSIGNED`)?**
Then `-1 < 0` evaluates false, and any loop with a negative bound or a "less than zero" test breaks. Many ISAs offer both (`slt`/`sltu`). Add `SLTU` if you need unsigned compares; don't change SLT.

**Q7. How would you add floating point?**
Add an FP pipe (FADD, FMUL, FFMA) as a fifth unit with 3–4 cycle latency, which leads straight into Q2. Choices to make:
- IEEE-754 single precision with round-to-nearest only;
- denormals flushed to zero (common in GPUs, and it saves area);
- a fused multiply-add, which is more accurate than separate multiply and add.

The DV reference model would then use SystemVerilog `shortreal`, or a C model through DPI.

**Q8. Why 8 lanes and not 32 like a real warp?**
Simulation speed and readability. Every structure scales with `LANES`: the register file width, the coalescer, the shared-memory banks. Real SMs build a 32-thread warp from a 16-wide unit run for 2 cycles, which is called *warp pumping*. That is another way to change the width without changing the ISA.
