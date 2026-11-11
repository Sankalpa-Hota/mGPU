# mGPU overview: the chip, the ISA and the testbench style

## What mGPU is, in plain words

A CPU is a few very clever workers. A GPU is a big crowd of simple workers who all do the same step at the same time on different data: "add these two numbers" done for 8, 64 or thousands of pixels or array elements at once. mGPU is a small GPU built so that every idea in a real one shows up, but small enough that you can read every signal in a log.

The CPU never runs the GPU directly. It writes a **list of commands** into memory (the *ring buffer*), then tells the GPU "there is work up to here". The GPU reads the commands, sets itself up, and launches thousands of tiny programs (*threads*). Threads are grouped in bundles of 8 called **warps**; all 8 threads of a warp execute the same instruction in the same cycle on their own data. Warps live inside an **SM** (streaming multiprocessor), and each SM is split into **sub-cores** so it can issue from more than one warp per cycle. Threads read and write memory through caches, a crossbar, an address translator (MMU) and finally an AXI bus to DRAM.

## The whole chip

```tree
mGPU | the complete chip | root
  RBBM | CPU register port (APB), interrupts, hang detect, perf counters | comp
  CP: ring fetch | reads the command ring from memory | comp
  CP: packet decoder | turns PM4 packets into register writes and opcodes | comp
  CP: SQE micro-sequencer | executes DISPATCH, EVENT_WRITE, WAIT_FOR_IDLE | comp
  Dispatcher | splits a kernel launch into workgroups and warps | comp
  SM x2 | streaming multiprocessor | comp
    I-cache | instruction cache shared by the sub-cores | comp
    Sub-core x2 | warp scheduler, scoreboard, SIMT stacks, register file, ALU, SFU | comp
    LSU | load/store unit: address generation, coalescing | comp
    Shared memory + barrier | 1 KB scratchpad per SM, workgroup barrier | comp
    L1 data cache | per SM, write-through | comp
  Crossbar | connects SMs and CP fetch to the L2 banks | comp
  L2 / UCHE | 2 banks, write-back, shared by everything | comp
  MMU | TLB + page-table walker, VA to PA | comp
  GBIF | AXI4 master toward DRAM | comp
  DRAM controller + memory | AXI4 slave, the real storage | comp
```

## Sizes and why

| Item | Value | Why this size |
|---|---|---|
| Threads per warp | 8 | Big enough to show divergence, coalescing and bank conflicts; small enough to read in logs |
| Warps per sub-core | 4 | The scheduler needs several warps to hide memory latency by switching |
| Sub-cores per SM | 2 | Shows how an SM splits issue bandwidth and shares the LSU and shared memory |
| SMs | 2 | Two requesters are the minimum that create contention on the crossbar and L2 |
| Registers per thread | 16 x 32 bit, r0 = 0 | 4-bit register fields fit a 32-bit instruction comfortably |
| Shared memory per SM | 1 KB, 8 banks | One bank per lane, so a conflict-free access serves a warp in one cycle |
| Cache line | 32 bytes = 8 words | One line is exactly one warp's coalesced access |
| Data width | 32 bit | |

## Who accesses whom, and for what

This table is the map of the chip. "Initiator" starts the transfer; "target" answers.

| Initiator | Target | What for | Protocol |
|---|---|---|---|
| CPU (testbench) | RBBM | program registers (ring base, WPTR, interrupt mask, watchdog, perf counters), read status | APB |
| RBBM | CP ring fetch | ring base and WPTR: "work exists up to here" | register level |
| CP ring fetch | below-L2 arbiter -> MMU -> GBIF -> DRAM | read command lines (**uncached**: the CPU writes the ring directly in DRAM) | line port |
| CP ring fetch | packet decoder | command dwords | valid/ready |
| Packet decoder | dispatcher, control registers | type 4 register writes (they wait for the SQE so they stay in order) | register bus |
| Packet decoder | SQE | type 7 operation dwords | valid/ready |
| SQE | dispatcher | DISPATCH: start a kernel with N workgroups | valid/ready |
| SQE | below-L2 arbiter -> MMU -> DRAM, RBBM | fence write (**uncached**), then the interrupt | line port, pulse |
| Dispatcher | SM sub-cores | launch a workgroup into a free slot | pulse (slot bookkeeping) |
| SM sub-cores | dispatcher | workgroup done | pulse |
| GMU / dispatcher | each other | SM available / SM wanted | levels |
| Warp scheduler | I-cache | fetch instructions | valid/ready |
| I-cache | SM memory port | line fills | line port |
| LSU | shared memory / L1 | LDS-STS / LD-ST | valid/ready |
| L1 | SM memory port | fills and write-through stores | line port |
| SM | crossbar -> L2 bank | line reads and writes | line port + id |
| L2 banks | below-L2 arbiter -> MMU | fills, write-backs (virtual addresses) | line port |
| MMU (walker) | GBIF -> DRAM | page-table reads | line port |
| GBIF | DRAM controller | physical reads and writes | AXI4 |
| Every block | SQE (WAIT_FOR_IDLE), RBBM | busy bits: 0 dispatcher + SMs, 1 L2, 2 memory path, 3 command fetch; perf events | levels |

## Control registers written by commands

| Register | Meaning |
|---|---|
| 0x100 / 0x101 / 0x102 | kernel pc / warps per workgroup / argument base (dispatcher) |
| 0x200 / 0x201 | MMU page table base / MMU enable |
| 0x202 | TLB invalidate (any write) |
| 0x203 | L2 flush: write back dirty lines and invalidate (any write) |
| 0x204 | GMU idle limit (cycles before an idle SM is powered off; 0 = never) |
| 0x205 | clear the MMU fault record (any write) |

## The mGPU ISA

Every instruction is 32 bits. One program (a *kernel*) is run by every thread; each thread finds its own data by reading its id with `S2R`.

**Encoding**

| Bits | Field | Meaning |
|---|---|---|
| [31:26] | opcode | which operation (table below) |
| [25:22] | rd | destination register; for ST/STS it is the register holding the data to store; for branches it is the first compare register |
| [21:18] | rs1 | first source register (the address base for memory ops; the second compare register for branches) |
| [17:14] | rs2 | second source register (R-type only) |
| [17:0] | imm | 18-bit signed immediate (I-type: ADDI, LUI, S2R, LD, ST, LDS, STS) |
| [17:9] / [8:0] | target / join | branches: signed target offset and unsigned forward offset of the reconvergence point, both in instructions |

**Operations**

| Opcode | Mnemonic | What each active thread does | Unit |
|---|---|---|---|
| 0x00 | NOP | nothing | - |
| 0x01-0x09 | ADD SUB MUL AND OR XOR SHL SHR SLT | rd = rs1 op rs2 (SLT: signed less-than gives 1 or 0) | ALU |
| 0x0A | ADDI | rd = rs1 + imm | ALU |
| 0x0B | LUI | rd = imm << 14 (builds big constants with ADDI) | ALU |
| 0x0C | S2R | rd = special register imm: 0 lane id, 1 warp id in workgroup, 2 workgroup id, 3 global thread id, 4 kernel argument base | ALU |
| 0x10-0x12 | DIV REM ISQRT | multi-cycle integer divide, remainder, integer square root | SFU |
| 0x18 / 0x19 | LD / ST | rd = mem[rs1+imm] / mem[rs1+imm] = rd | LSU → L1 |
| 0x1A / 0x1B | LDS / STS | same, but to the SM's shared memory | LSU → shared memory |
| 0x20 / 0x21 | BEQ / BNE | branch if rd == rs1 (or !=); threads may split; they rejoin at the join point | SIMT stack |
| 0x22 | JMP | uniform jump by target offset | fetch |
| 0x23 | BAR | wait until every warp of the workgroup reaches this barrier | barrier unit |
| 0x3F | EXIT | the thread is finished; when all threads of a warp exit the warp retires | scheduler |

**A first kernel: c[i] = a[i] + b[i]**

```
S2R  r1, 3          // r1 = global thread id i
S2R  r2, 4          // r2 = argument base (holds addresses of a, b, c)
LD   r3, [r2+0]     // r3 = address of a
LD   r4, [r2+4]     // r4 = address of b
LD   r5, [r2+8]     // r5 = address of c
ADDI r6, r0, 2
SHL  r7, r1, r6     // r7 = i * 4 (byte offset)
ADD  r3, r3, r7
ADD  r4, r4, r7
ADD  r5, r5, r7
LD   r8, [r3+0]     // a[i]
LD   r9, [r4+0]     // b[i]
ADD  r10, r8, r9
ST   r10, [r5+0]    // c[i] = a[i] + b[i]
EXIT
```

## The command stream (PM4 subset)

The CPU fills the ring with **packets**. The first dword of a packet is the **header**; it says what kind of packet it is and how many **payload** dwords follow.

| Packet | Header bits | Meaning |
|---|---|---|
| Type 4 | `[31:28]=4`, `[25:8]` first register, `[6:0]` count | write `count` consecutive registers starting at the given one |
| Type 7 | `[31:28]=7`, `[22:16]` opcode, `[13:0]` count | perform an operation with `count` payload dwords |
| Anything else | other values in `[31:28]` | illegal: the decoder raises a sticky `bad_pkt` error |

Type 7 opcodes: `0x01 DISPATCH` (payload: number of workgroups), `0x02 EVENT_WRITE` (payload: fence address, fence value; also raises an interrupt), `0x03 WAIT_FOR_IDLE` (payload: a mask of busy bits; waits until every selected busy bit is low). Every operation has at least one payload dword, because a zero-count type 7 packet produces no output from the decoder and would never reach the SQE.

**Example ring content that launches the vector-add kernel**

| Dword | Meaning |
|---|---|
| `0x40010003` | type 4, first register 0x00100, 3 registers follow |
| `0x00000000` | 0x100 KERNEL_PC = 0 |
| `0x00000002` | 0x101 WARPS_PER_WG = 2 (so a workgroup is 16 threads) |
| `0x00001000` | 0x102 ARG_BASE = 0x1000 |
| `0x70010001` | type 7, DISPATCH, 1 payload dword |
| `0x00000004` | 4 workgroups |
| `0x70030001`, `0x000000FF` | type 7, WAIT_FOR_IDLE, wait for all 8 busy bits |
| `0x70020002` | type 7, EVENT_WRITE, 2 payload dwords |
| `0x00002000`, `0x00000001` | write fence value 1 to address 0x2000, raise IRQ |

## Handshakes used everywhere

**valid/ready.** The sender raises `valid` and holds the data. The receiver raises `ready` when it can take it. A transfer happens on a clock edge where both are 1. Two rules make it safe: the sender must not drop `valid` or change the data while waiting, and the sender must not wait for `ready` before raising `valid` (otherwise both sides could wait forever).

```wave
clk   | pppppppp
valid | 01111100
ready | 00011100
data  | x=====xx | A A A B C
```

Data A waits two cycles (valid without ready), then A, B and C move on three consecutive edges.

**AXI4** (GBIF to DRAM) is five valid/ready channels: read address (AR), read data (R), write address (AW), write data (W) and write response (B). **APB** (CPU to RBBM) is a simple two-cycle register bus: setup, then enable.

## Repository layout and file naming

| Path | Contents |
|---|---|
| `rtl/<NN>_<block>/` | the synthesizable design of one block |
| `tb/<NN>_<block>/` | its UVM testbench, Makefile, and `logs/` after a run |
| `tb/common/` | shared make rules (`sim.mk`) and the coverage bin counter |
| `scripts/` | log checker, coverage merge, full regression |
| `docs/src/` | the Markdown source of these documents |
| `docs/modules/` | one PDF per block |
| `uvm/` | the UVM library ported to Verilator (Apache 2.0) |

Inside a testbench folder every file starts with the block name and ends with its role: `<block>_interface`, `<block>_transactions`, `<block>_sequences`, `<block>_driver`, `<block>_monitor`, `<block>_agent`, `<block>_reference_model`, `<block>_scoreboard`, `<block>_coverage`, `<block>_assertions`, `<block>_env`, `<block>_tests`, `<block>_pkg` and `<block>_tb_top`.

## How every testbench is built (the same pattern for every block)

```hflow
Sequence --> Driver --> DUT --> Monitor
```

```hflow
Monitor -input-> Reference model -expected-> Scoreboard
Monitor -actual output-> Scoreboard
Reference model -observations-> Coverage
```

| Piece | Plain-words job |
|---|---|
| Transaction | one unit of work described as data (a packet, a request, an instruction) |
| Sequence | the "test writer": creates many transactions, random within rules (constraints) or fixed (directed) |
| Driver | turns a transaction into pin wiggles, cycle by cycle, obeying the handshake |
| Monitor | only watches pins and turns what it sees back into transactions; never drives anything |
| Reference model | an independent, untimed program that says what the DUT *should* produce for the inputs the monitor saw |
| Scoreboard | compares expected against actual, and reports any difference as a UVM_ERROR |
| Coverage | counts which interesting situations really happened, so we know the tests were good enough |
| Assertions | cycle-level rules written in SVA that run all the time inside the simulation |
| Test | picks the sequence and the knobs (how random, how much backpressure) |

**Why the reference model listens to the monitor and not to the sequence.** What the sequence *meant* to send is not always what reached the DUT (a driver bug, a dropped beat). Predicting from what really crossed the pins makes the check honest.

**Why coverage is a bin counter and not a covergroup.** Verilator parses SystemVerilog covergroups but does not count their bins, so a covergroup would always report 0%. `tb/common/mgpu_coverage.sv` keeps a named counter per bin, prints the percentage, and lists every bin with its hit count. `scripts/merge_coverage.py` adds the counts of every run in the regression, because coverage closure is judged on the whole regression, not on one test.

**Why every block has planted bugs.** A testbench that never fails proves nothing. Each RTL file contains one or more `ifdef BUG_...` lines that plant a realistic mistake. `make bugs` rebuilds with each one and checks the test now **fails**. If a bug is not caught, the testbench is missing a check.

## How to run

| Command (inside `tb/<block>/`) | What it does |
|---|---|
| `make build` | compile RTL + testbench with Verilator (about 2 minutes, mostly UVM) |
| `make run TEST=<name> SEED=<n>` | one test; writes `logs/<test>_s<n>.log` and a text waveform `logs/<test>_s<n>_wave.txt` |
| `make regress` | every test x every seed, a PASS/FAIL line each, then merged coverage in `logs/coverage_merged.txt` |
| `make bugs` | rebuild with each planted bug and confirm the testbench catches it |
| `scripts/regress_all.sh` | all blocks, one summary |

A test **passes** when the UVM report shows `UVM_ERROR : 0` and `UVM_FATAL : 0`. Scoreboard mismatches and assertion failures both report as UVM_ERROR, so either one fails the test. No VCD/VPD is dumped; instead the text waveform logs one line per cycle for the first 200 cycles, which is enough to read any handshake by eye.

# Teaching section: the whole chip in context

## The chip and its pins

```pins
block: mGPU | mgpu_top.sv · 2 SMs x 2 sub-cores · 8-lane warps · 2 L2 banks · AXI4 to DRAM
in: psel, penable, pwrite, paddr[11:0], pwdata | CPU | APB register access into the RBBM
in: arready | DRAM controller | AXI read address accepted
in: rvalid, rdata, rresp, rlast | DRAM controller | AXI read data beats
in: awready, wready | DRAM controller | AXI write address / write data accepted
in: bvalid, bresp | DRAM controller | AXI write response
in: dram_perf[15:0] | DRAM controller | row hit / row miss events for the perf counters
out: prdata, pready, pslverr | CPU | APB read data, ready, error
out: irq | CPU interrupt controller | fence, bad packet, bad op or hang (masked by IRQ_MASK)
out: mmu_fault, mmu_fault_va | CPU | the MMU met a missing translation, and its virtual address
out: arvalid, araddr, arlen, arsize, arburst | DRAM controller | AXI read address
out: rready | DRAM controller | GPU can take read data
out: awvalid, awaddr, awlen, awsize, awburst | DRAM controller | AXI write address
out: wvalid, wdata, wstrb, wlast | DRAM controller | AXI write data
out: bready | DRAM controller | GPU can take the write response
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

The whole chip has only three kinds of outside connection: a **control port** (APB in, plus `irq` and `mmu_fault` out), a **memory port** (AXI4 master toward DRAM), and clock/reset. `mgpu_system.sv` wraps `mgpu_top` together with the DRAM controller, so a system-level test only sees APB and the interrupt pins.

## Where everything sits: command to compute to memory

```hflow
CPU | driver -APB-> RBBM | registers -wptr-> CP | fetch, decode, SQE -DISPATCH-> Dispatcher | workgroups -launch-> SM x2 | warps run | you -line req-> Crossbar and L2 | 2 banks -miss-> MMU | VA to PA -AXI4-> DRAM | storage
```

| Layer | Blocks | Job |
|---|---|---|
| Control | RBBM (04) | the CPU's register window, interrupts, watchdog, counters |
| Command | Ring fetch (02), packet decoder (01), SQE (03) | read and execute the command stream in order |
| Work distribution | Dispatcher (05), GMU (21) | turn a kernel into workgroups, keep SMs powered when needed |
| Compute | SM (15): I-cache, sub-cores with scheduler, SIMT stack, collector, ALU, SFU, LSU, shared memory, L1 | run the threads |
| Memory | Crossbar (16), L2 (17), below-L2 arbiter, MMU (18), GBIF (19), DRAM (20) | serve lines, translate addresses, talk AXI |

## Life of a kernel

This walks through the vector-add launch from the command-stream example above, from the CPU's first write to the interrupt.

1. **The CPU prepares memory.** It writes the kernel's program, its input arrays and its argument block into DRAM, then writes the command packets into the ring: a type 4 packet for registers 0x100-0x102, a DISPATCH of 4 workgroups, a WAIT_FOR_IDLE, and an EVENT_WRITE fence.
2. **The doorbell.** Over APB the CPU writes RING_BASE (once) and then RING_WPTR. The RBBM drives `ring_wptr` to the ring fetch.
3. **Fetch.** The ring fetch sees `wptr != fptr`, reads the ring a 32-byte line at a time through the uncached path below the L2 (arbiter, MMU, GBIF, AXI, DRAM), and pushes dwords into its FIFO.
4. **Decode.** The packet decoder reads the type 4 header and writes KERNEL_PC, WARPS_PER_WG and ARG_BASE into the dispatcher's `cfg_*` registers. Then it sees the type 7 DISPATCH header and passes the payload "4" to the SQE.
5. **Dispatch.** The SQE offers DISPATCH to the dispatcher. On accept, the dispatcher latches the configuration, and the same handshake (`kernel_start`) invalidates the SM instruction caches and L1s so no stale program or data is used. The dispatcher asks the GMU for the SMs (`sm_want`) and, as slots are free and available, launches workgroups 0, 1, 2, 3 round-robin across the four sub-core slots.
6. **Compute.** Each sub-core starts its warps at KERNEL_PC. Each warp's scheduler fetches through the I-cache, the collector reads registers, the ALU computes addresses with S2R and arithmetic, and the LSU coalesces loads into 32-byte lines. Misses go from the L1 to the SM's memory port, across the crossbar to an L2 bank, and on an L2 miss down through the MMU and GBIF to DRAM. Stores go through the write-through L1 into the write-back L2.
7. **Completion.** Each warp ends with EXIT. When all warps of a workgroup are done, the sub-core pulses `wg_done`, and the dispatcher clears that slot. Busy bit 0 stays high until the last slot is free.
8. **Wait.** Meanwhile the SQE is executing WAIT_FOR_IDLE: it waits its settle cycles, then until all selected busy bits are low.
9. **Fence and interrupt.** The SQE writes the fence value to its address through the uncached path, waits for the write acknowledgment, then pulses `irq` into the RBBM. IRQ_STATUS bit 0 is set and, if unmasked, the `irq` pin rises.
10. **The CPU wakes up.** It reads IRQ_STATUS, writes 1 to bit 0 to clear it, reads the fence value from DRAM, and reads the results. If the results live in the write-back L2, the command stream must also include an L2 flush (register 0x203) and a WAIT_FOR_IDLE before the fence, so the data reaches DRAM.

## Questions: what if we built the chip differently?

**Q1. What if we had 8 SMs instead of 2?**
The dispatcher would need more slots (`NSM` is a parameter), the crossbar would grow from 2x2 toward 8 inputs, and the L2 would likely need more banks to keep up. Peak compute rises four times, but only if the memory system can feed it; otherwise SMs stall on L2 and DRAM. The busy bit and power control (GMU) would grow per SM. Testbenches would need many more workgroups per kernel to keep all SMs busy, and contention tests on the crossbar become much more important.

**Q2. What if a warp had 32 threads like NVIDIA (or 64 like AMD wavefronts)?**
Every per-lane structure widens: the register file, ALU lanes, the LSU coalescer, shared-memory banks. A 32-byte line would no longer cover one warp's coalesced access, so the line size would likely grow to 128 bytes. Wider warps amortize instruction fetch and scheduling over more threads, but divergence wastes more lanes (one taken branch idles up to 31 lanes). Logs become much harder to read, which is why mGPU uses 8.

**Q3. What if the L1s were kept coherent with a protocol like MESI instead of being invalidated at kernel start?**
Today the L1 is write-through and is simply invalidated at each kernel start; between SMs within a kernel there is no coherence, which matches the GPU programming model (threads in different workgroups must not depend on each other's writes without atomics or fences). MESI would need snoops or a directory at the L2, extra state bits per line, and invalidation traffic. It makes sharing between SMs correct at any time, but costs area and bandwidth that GPU workloads rarely need. Testbenches would need multi-SM sharing tests and a coherence checker.

**Q4. What if the CPU and GPU shared one unified, coherent memory?**
Then the ring and fences would not need the uncached path, and the CPU could pass pointers directly. The GPU would need to snoop or be snooped by the CPU caches (for example through a coherent interconnect such as CHI or CXL), and the MMU would use the CPU's page tables. Programming becomes easier, and copies disappear. Hardware becomes much more complex, and memory latency for the GPU may rise. The system testbench would need a CPU cache model.

**Q5. What if the MMU were removed (physical addresses only)?**
The chip gets smaller and every memory access saves a TLB lookup. But two processes could not safely share the GPU, and the driver must allocate physically contiguous buffers. With the MMU, page faults are reported on `mmu_fault` and `mmu_fault_va`, which is how a driver finds bad pointers. The MMU tests and the fault interrupt path would disappear.

**Q6. What if the L2 were write-through instead of write-back?**
Every store would go to DRAM, so the CPU would see results without an explicit L2 flush, which simplifies fences. But DRAM write traffic would rise sharply, especially for kernels that write the same line several times. With write-back, the L2 absorbs repeated writes and the driver flushes once at the end.

**Q7. What if the CPU fed the GPU through MMIO register writes instead of a ring in memory?**
There would be no ring fetch, but every command dword would cost an APB write and the CPU could not queue work ahead. Real GPUs all use rings (or queues) in memory with a doorbell register, because it lets the CPU move on while the GPU works.

**Q8. What if completion were signalled only by polling memory, with no interrupt?**
The chip would lose the `irq` pin and the RBBM interrupt logic. The CPU would spin on the fence address, which is fine for a dedicated compute loop but wastes power and CPU time otherwise. mGPU supports both: the fence value is in memory, and the interrupt can be masked.

**Q9. What if the SMs could be clocked or powered independently (DVFS) beyond the GMU's on/off gating?**
The GMU today only switches an SM on or off and waits a few wake cycles. Real GPUs also change voltage and frequency per domain. That needs clock-domain crossings between SMs and the crossbar, a power controller with voltage tables, and much harder verification (asynchronous FIFOs, CDC checks). Power drops for light workloads; complexity rises a lot.

**Q10. What if the interconnect between SMs and L2 were a ring or a mesh network instead of a crossbar?**
A crossbar gives every SM a direct path to every bank, which is cheap at 2x2 but grows with the square of the size. A ring or mesh network-on-chip scales to many SMs with fewer wires, but adds hops of latency and needs routing, buffering and deadlock avoidance. At mGPU's size the crossbar is the clear choice; at 100 SMs it is not. Testbenches would need traffic generators and latency and fairness checks.
