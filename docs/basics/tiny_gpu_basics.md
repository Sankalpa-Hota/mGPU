# GPU basics with tiny-gpu

This guide explains **tiny-gpu** ([github.com/adam-maj/tiny-gpu](https://github.com/adam-maj/tiny-gpu), by Adam Majmudar) in simple words. tiny-gpu is about 1,300 lines of Verilog. It is the smallest design we know that still shows the main idea of a GPU: **many threads running the same instruction at the same time, each on its own data**.

Read this first, then read mGPU. mGPU is built on the same idea, but adds the parts that a real GPU needs to be fast (warps, caches, branch splitting, a command processor). If you know tiny-gpu, every mGPU block will feel like "the tiny-gpu version, made better". The last chapter maps each tiny-gpu part to the mGPU block that replaces it.

All the facts here were checked against the tiny-gpu source code (`src/*.sv`, last commit May 2024). Its README has nice pictures of the chip, the core and the ISA; open it next to this guide.

## 1. What a GPU is, in one page

A **CPU** is a few very smart workers. Each one runs its own program and is good at jumping around, making decisions and finishing one task fast.

A **GPU** is a big crowd of simple workers who all follow **one shared list of instructions**. The trick: each worker has its own number (its *thread id*), so when the list says "load element number *my id*", every worker loads a different element. One instruction, many pieces of data. This is called **SIMD** (single instruction, multiple data). NVIDIA calls the same idea **SIMT** (single instruction, multiple threads).

This is perfect for jobs like "add two arrays of a million numbers": the work for element 5 does not depend on element 4, so all of them can run at once.

Words you will see everywhere:

| Word | Meaning in plain words |
|---|---|
| Kernel | the small program every thread runs (for example: `C[i] = A[i] + B[i]`) |
| Thread | one worker running the kernel on its own element `i` |
| Block | a group of threads that runs together on one core (mGPU calls it a *workgroup*) |
| Core | the hardware that runs one block; it has one copy of the units per thread |
| `threadIdx`, `blockIdx`, `blockDim` | the numbers a thread uses to find its element: `i = blockIdx * blockDim + threadIdx` |
| Global memory | the big shared memory outside the chip (DRAM in a real GPU) |

Example: 8 threads, blocks of 4. Block 0 has threads 0-3, block 1 has threads 0-3 again. Thread 2 of block 1 computes `i = 1 * 4 + 2 = 6`, so it works on element 6.

## 2. tiny-gpu at a glance

tiny-gpu runs **one kernel at a time**. The default build has **2 cores**, each running **one block of 4 threads**. Data is **8 bits** wide, and both memories have only **256 rows**.

```hflow
Testbench | loads memories, sets thread count, raises start -thread count-> Device control register | holds thread count -start-> Dispatcher | hands out blocks -block id-> Core x2 | 4 threads each
Core x2 | 4 threads each -fetch-> Program memory controller | 1 channel -16-bit words-> Program memory | 256 x 16 bit
Core x2 | 4 threads each -load / store-> Data memory controller | 4 channels -8-bit words-> Data memory | 256 x 8 bit
```

| Part | File | Job |
|---|---|---|
| Device control register (DCR) | `dcr.sv` | one 8-bit register: how many threads the kernel needs in total |
| Dispatcher | `dispatch.sv` | cuts the threads into blocks, gives each free core a block, says "done" when all blocks finish |
| Core | `core.sv` | runs one block: shared fetcher, decoder and scheduler, plus one register file, ALU, LSU and PC **per thread** |
| Memory controller | `controller.sv` | many requesters, few memory channels: picks who goes next and sends the answer back to the right requester |
| GPU top | `gpu.sv` | wires everything together |

The memories themselves are not in the Verilog. The Python testbench (cocotb) pretends to be them.

## 3. Starting a kernel

The testbench does four things:

1. Writes the kernel's instructions into **program memory**.
2. Writes the input numbers into **data memory**.
3. Writes the total thread count into the **DCR**.
4. Raises the `start` pin, then waits for the `done` pin.

### The dispatcher

The dispatcher first works out how many blocks it needs:

`total_blocks = (thread_count + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK` (divide and round up)

Then, every cycle, for each core:

- If the core was just reset and blocks are left, it gives the core the next **block id** and raises that core's `start`.
- The **last** block may be smaller. With 10 threads and blocks of 4 you get 3 blocks: 4, 4 and **2**. The dispatcher tells the core "only 2 threads", and the core switches off the units of the unused threads.
- When a core raises `done`, the dispatcher resets it, counts the block as finished, and the core becomes free for the next block.
- When finished blocks = total blocks, it raises the GPU's `done`.

Example with 10 threads and 2 cores: core 0 gets block 0 and core 1 gets block 1. Whichever finishes first gets block 2 (2 threads).

## 4. Memory and the memory controller

tiny-gpu keeps **instructions** and **data** in separate memories (this is called a Harvard layout). It is simpler, because fetching an instruction never has to wait for a data load.

| Memory | Address | Word | Who uses it |
|---|---|---|---|
| Program memory | 8 bits (256 rows) | 16 bits = one instruction | the fetcher of each core (read only) |
| Data memory | 8 bits (256 rows) | 8 bits = one number | the LSU of each thread (read and write) |

**Why a memory controller?** 2 cores × 4 threads = **8 LSUs** may all want data memory in the same cycle, but memory has only **4 channels** (4 requests in flight at once). The controller does this for each channel:

```flow
box: IDLE | look through the requesters; take the first one that is waiting and that no other channel is serving
arrow: read or write found
box: WAITING | send the address (and data, for a write) to memory; wait for memory's ready | hw
arrow: memory answered
box: RELAYING | hand the answer to that requester; wait until it drops its valid
back: back to IDLE
```

This is the core of **every** GPU memory system: lots of requesters, limited bandwidth, so someone has to queue requests and route answers back. In mGPU the same job is spread over the L1 arbiter, the crossbar, the L2 banks and the line arbiter in front of the MMU.

## 5. Inside a core

A core has some parts **shared by all its threads** and some parts **copied once per thread**.

```tree
Core | runs one block | root
  Shared by all threads | one copy per core | comp
    Fetcher | reads the instruction at the current PC from program memory | comp
    Decoder | turns the 16-bit instruction into control signals | comp
    Scheduler | the core's state machine: steps every thread through each instruction together | comp
  One copy per thread | 4 copies per core | comp
    Register file | 16 registers of 8 bits; R13-R15 are read-only ids | comp
    ALU | ADD, SUB, MUL, DIV, CMP | comp
    LSU | does LDR and STR, waits for memory | comp
    PC unit | works out the next PC; holds the NZP flags for branches | comp
```

Because all threads share **one** fetcher and **one** decoder, they all run the **same instruction**. Because each thread has its **own** registers, they run it on **different data**. That is SIMD in hardware.

### The registers

Each thread has 16 registers of 8 bits:

| Register | What it holds | Writable? |
|---|---|---|
| R0-R12 | normal working registers | yes |
| R13 = `%blockIdx` | which block this thread belongs to (set by the dispatcher) | no |
| R14 = `%blockDim` | threads per block (4) | no |
| R15 = `%threadIdx` | this thread's number inside the block (0-3, fixed in hardware) | no |

The three read-only registers are the **only** thing that makes threads behave differently. Take them away and all four threads would compute exactly the same thing.

## 6. How one instruction runs: the 6 steps

The scheduler moves the whole core through these states for **every** instruction:

```flow
box: FETCH | fetcher asks program memory for the instruction at PC; wait for it
arrow: instruction arrived
box: DECODE | decoder sets the control signals (1 cycle)
arrow:
box: REQUEST | every thread reads its two source registers; LSUs send loads or stores (1 cycle) | hw
arrow:
box: WAIT | stay here until every LSU has its answer (only slow for LDR / STR)
arrow: all LSUs done
box: EXECUTE | every ALU computes; every PC unit works out the next PC (1 cycle) | hw
arrow:
box: UPDATE | write the result register and NZP flags; PC = next PC; RET ends the block (1 cycle) | ok
back: back to FETCH for the next instruction (or DONE after RET)
```

Things to notice:

- **One instruction at a time.** An ADD takes about 5 cycles plus the fetch, and the next instruction does not start until the current one finishes. There is no **pipelining** (overlapping instructions).
- **WAIT stops everyone.** If one thread's load is slow, all four threads wait, and the core does nothing useful meanwhile. Real GPUs hide this wait by switching to a different group of threads (warp scheduling). That is the single biggest idea mGPU adds.
- **One PC for the whole core.** At UPDATE the scheduler takes the next PC of the **last** thread and uses it for everyone. If threads wanted to go different ways at a branch, that difference is lost (more in chapter 8).

## 7. The instruction set (ISA)

Every instruction is **16 bits**. The top 4 bits say which instruction it is. The rest are register numbers or a constant.

| Bits | 15-12 | 11-8 | 7-4 | 3-0 |
|---|---|---|---|---|
| Field | opcode | `rd` (destination) | `rs` (source 1) | `rt` (source 2) |
| For CONST / BRnzp | opcode | `rd`, or `nzp` in bits 11-9 | 8-bit constant (bits 7-0) | |

| Instruction | Opcode | What it does |
|---|---|---|
| `NOP` | 0000 | nothing |
| `BRnzp` | 0001 | jump to the constant address if the NZP flags match the condition |
| `CMP rs, rt` | 0010 | compare: set flags N (negative), Z (zero), P (positive) from `rs - rt` |
| `ADD rd, rs, rt` | 0011 | `rd = rs + rt` |
| `SUB rd, rs, rt` | 0100 | `rd = rs - rt` |
| `MUL rd, rs, rt` | 0101 | `rd = rs * rt` |
| `DIV rd, rs, rt` | 0110 | `rd = rs / rt` |
| `LDR rd, rs` | 0111 | `rd = memory[rs]` |
| `STR rs, rt` | 1000 | `memory[rs] = rt` |
| `CONST rd, #k` | 1001 | `rd = k` |
| `RET` | 1111 | this thread is finished |

That is all: no AND/OR/shift, no immediate add, no shared memory, no barrier. It is just enough for matrix addition and matrix multiplication.

## 8. Walking through a kernel: matrix addition

This is tiny-gpu's `matadd` kernel (from its README): add two lists of 8 numbers, `C[i] = A[i] + B[i]`, using 8 threads. A starts at address 0, B at 8 and C at 16.

```asm
MUL   R0, %blockIdx, %blockDim
ADD   R0, R0, %threadIdx      ; i = blockIdx * blockDim + threadIdx
CONST R1, #0                  ; base of A
CONST R2, #8                  ; base of B
CONST R3, #16                 ; base of C
ADD   R4, R1, R0              ; address of A[i]
LDR   R4, R4                  ; R4 = A[i]
ADD   R5, R2, R0              ; address of B[i]
LDR   R5, R5                  ; R5 = B[i]
ADD   R6, R4, R5              ; R6 = A[i] + B[i]
ADD   R7, R3, R0              ; address of C[i]
STR   R7, R6                  ; C[i] = R6
RET
```

8 threads with blocks of 4 gives 2 blocks, one on each core. After the first two lines, each thread holds a different `i`:

| | core 0, thread 0 | thread 1 | thread 2 | thread 3 | core 1, thread 0 | thread 1 | thread 2 | thread 3 |
|---|---|---|---|---|---|---|---|---|
| `%blockIdx` | 0 | 0 | 0 | 0 | 1 | 1 | 1 | 1 |
| `%threadIdx` | 0 | 1 | 2 | 3 | 0 | 1 | 2 | 3 |
| `i` (R0) | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| loads from | 0 and 8 | 1 and 9 | 2 and 10 | 3 and 11 | 4 and 12 | 5 and 13 | 6 and 14 | 7 and 15 |
| stores to | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 |

Every thread runs the exact same 13 instructions, and the only reason they touch different addresses is `%blockIdx` and `%threadIdx`. This is the whole GPU programming model in one table.

At the `LDR` line, all 8 LSUs ask data memory at once. Memory has 4 channels, so the controller serves 4 requests and the other 4 wait their turn. Notice that threads 0-3 read **neighbouring** addresses 0, 1, 2, 3. A real GPU would fetch those in **one** wide memory access (this is called **coalescing**). tiny-gpu sends 4 separate requests. mGPU's LSU does coalesce.

## 9. Branches and loops: CMP + BRnzp

tiny-gpu does loops the old LC-3 way:

1. `CMP R9, R2` computes `R9 - R2` and sets three flags: **N** (result below zero), **Z** (equal to zero), **P** (above zero).
2. `BRn LOOP` jumps to `LOOP` only if the N flag is set, which means `R9 < R2`. `BRz` jumps when they are equal, `BRnz` on "less or equal", and so on.

The `matmul` kernel (2×2 matrices, 4 threads) uses this for its `k` loop: `k = k + 1; CMP k, N; BRn LOOP`. That is the intended meaning; chapter 10 shows what the hardware really checks.

**The big simplification: no divergence.** Every thread has its own PC unit and its own flags, so in theory every thread could decide differently. But the scheduler keeps **one** PC for the core, and copies the last thread's choice to everyone. This works for matmul because every thread runs the loop the same number of times. It would give **wrong answers** for code like `if (threadIdx < 2) { ... }`.

Real GPUs handle this with a **SIMT stack** and an **active mask**: run the "if" side with only the threads that took it switched on, then run the other side with the rest, then join back together. mGPU's block 08 does exactly this.

## 10. Small details worth noticing in the code

These are not complaints about tiny-gpu. They are good "what would break?" exercises before you read mGPU's RTL.

- **8-bit numbers wrap around.** `200 + 100` gives 44, because only the low 8 bits fit. The data memory has only 256 rows.
- **The compare is unsigned.** In `alu.sv`, `rs - rt` uses unsigned numbers, so "less than zero" is never true, and "greater than zero" is true whenever the two values differ. The `n` bit of the `BRn` instruction (bit 11) lines up with that "greater than zero" bit, so `BRn LOOP` actually loops while `k != N`. matmul still gives the right answer, because `k` counts up and hits N exactly. A real signed compare needs a sign bit; mGPU uses 32-bit signed `SLT`.
- **Divide is one cycle and has no divide-by-zero rule.** A real divider takes many cycles, which is why mGPU puts DIV/REM in a separate multi-cycle unit (the SFU) with a defined result for `x / 0`.
- **The cache is listed but not built.** The README marks the cache as work in progress, and there is no cache in `src/`. Every fetch and every load goes to memory.
- **The scheduler waits for `fetcher_state == 3'b010`.** States are compared as raw numbers across modules. mGPU puts shared names in one package (`mgpu_pkg`) so every block agrees on them.

## 11. From tiny-gpu to mGPU: what changes and where to look

| Idea | tiny-gpu | mGPU | mGPU block |
|---|---|---|---|
| Starting a kernel | testbench sets the thread count and raises `start` | the CPU writes commands into a ring in memory and rings a doorbell; the command processor reads and runs them | 04 RBBM, 02 ring fetch, 01 packet decoder, 03 SQE |
| Handing out work | dispatcher gives one block per core | dispatcher gives workgroups to free sub-cores and splits them into warps | 05 dispatcher |
| Thread group | one block of 4 threads per core | up to 4 **warps** of 8 threads per sub-core, 2 sub-cores per SM, 2 SMs | 15 SM |
| Running instructions | 6-step state machine, one instruction at a time | warp scheduler issues one ready warp per cycle; a scoreboard stops a warp only when its own registers are not ready | 07 warp scheduler |
| Waiting on memory | the whole core waits | that warp waits, other warps keep running (latency hiding) | 07, 13 |
| Branches | one PC per core, no divergence | each warp has a PC plus an active-thread mask; the warp splits and rejoins | 08 SIMT stack |
| Registers | a separate register file per thread | one banked register file for all warps, plus a collector that gathers operands | 09 register file + collector |
| Math | a full ALU per thread, single-cycle DIV | one 8-lane ALU shared by the warps; slow functions in a multi-cycle SFU | 10 ALU, 11 SFU |
| Loads and stores | one LSU per thread, one request each | one LSU per sub-core that merges lanes hitting the same line | 13 LSU |
| Sharing between threads | not possible | shared memory scratchpad plus a barrier (`BAR`) | 12 shared memory + barrier |
| Instruction memory | every fetch goes to program memory | I-cache per SM; instructions live in the same memory as data | 06 I-cache |
| Data memory | 256 bytes, reached through a controller | L1 per SM, crossbar, 2 L2 banks, virtual memory (MMU), AXI4 bus, DRAM with timing | 14, 16, 17, 18, 19, 20 |
| Finishing | `done` pin | fence write to memory plus an interrupt to the CPU | 03 SQE, 04 RBBM |
| Power | none | idle SMs are switched off and woken when work arrives | 21 GMU |
| Testing | 2 kernel tests, results checked by reading the log | UVM testbench per block with coverage and planted bugs; full-chip test compared with an instruction-set simulator | `tb/` |

**Suggested reading order for mGPU after this guide:**

1. `docs/modules/00_mGPU_overview.pdf`: the chip map, ISA and command stream.
2. Compute first, because it maps most directly to tiny-gpu's core: 07 warp scheduler, 08 SIMT stack, 09 register file, 10 ALU, 13 LSU, then 15 SM.
3. Memory next: 06, 14, 16, 17, 18, 19, 20.
4. The command path last: 04, 02, 01, 03, 05, 21, then 22 top.
