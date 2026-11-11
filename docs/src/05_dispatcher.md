# 05 Dispatcher

## What this block is, in plain words

A kernel launch says "run this program N times over, in N **workgroups**". The dispatcher hands those workgroups out to the hardware. mGPU has 2 SMs with 2 sub-cores each, and every sub-core can hold one workgroup, so there are 4 **slots**. The dispatcher keeps track of which slots are free, gives each new workgroup to a free slot, and waits when all slots are busy. It also tells the power manager which SMs it needs, and only uses SMs that are awake.

## Where it sits and who talks to it

```hflow
CP register bus -kernel config-> Dispatcher
SQE -DISPATCH (N workgroups)-> Dispatcher -launch workgroup-> SM sub-cores
SM sub-cores -workgroup done-> Dispatcher
GMU -SM available-> Dispatcher -SM wanted-> GMU
```

| Who | Talks to | For what | Signals |
|---|---|---|---|
| Packet decoder | dispatcher | kernel registers 0x100 KERNEL_PC, 0x101 WARPS_PER_WG, 0x102 ARG_BASE | `reg_wr_en`, `reg_wr_addr`, `reg_wr_data` |
| SQE | dispatcher | start a kernel with N workgroups | `disp_valid`, `disp_ready`, `disp_num_wg` |
| Dispatcher | SMs | launch one workgroup into slot s (SM s % 2, sub-core s / 2) | `launch_valid`, `launch_slot`, `launch_wg_id`, `launch_nwarps`, `launch_pc`, `launch_arg` |
| SMs | dispatcher | the workgroup in slot s has finished | `wg_done[3:0]` (one pulse) |
| GMU | dispatcher | which SMs are powered and usable | `sm_avail[1:0]` |
| Dispatcher | GMU, SQE, RBBM | which SMs it needs; whether anything is still running | `sm_want[1:0]`, `busy` |

## Architecture

```tree
dispatcher | workgroup launcher | root
  Config registers | written any time by the command stream | comp
  Latched kernel | pc, warps, argument copied at DISPATCH | comp
  remaining / next_wg | workgroups still to launch, next workgroup id | comp
  occ[3:0] | which slots hold a workgroup | comp
  Slot picker | first free, available slot from a round-robin pointer | comp
```

## RTL decisions and why

| Decision | Why |
|---|---|
| Configuration is **latched** when DISPATCH is accepted | The driver can program the next kernel while this one is still launching. Using the live registers would launch the remaining workgroups of kernel 1 with kernel 2's program (planted bug `BUG_LIVE_CONFIG`). |
| A new DISPATCH is accepted only when every workgroup of the previous one has been launched | One kernel's launch state at a time keeps the hardware small; the previous kernel's workgroups may still be running. |
| Launch has no ready signal: the dispatcher only launches into a slot it knows is free | The slot bookkeeping lives in one place. The SM never has to refuse a workgroup. |
| Slot order 0..3 alternates SMs (slot s on SM s % 2), picked round-robin | Consecutive workgroups go to different SMs, spreading work and memory traffic. |
| Only slots of available SMs are used | A power-gated SM cannot run work (planted bug `BUG_IGNORE_AVAIL`). |
| `busy` = workgroups still to launch **or** any slot occupied | WAIT_FOR_IDLE must wait for running workgroups too, not only for launching (planted bug `BUG_BUSY_EARLY`). |
| `sm_want` is high for every SM while work is waiting, and for an SM while it holds a workgroup | The GMU wakes SMs ahead of time and never powers off an SM that is running work. |

## Waveform (from the simulation)

Smoke test, cycles 8 to 11 (column 0 = cycle 8). DISPATCH with 2 workgroups is accepted in cycle 8. Workgroup 0 goes to slot 0 in cycle 9, workgroup 1 to slot 1 (the other SM) in cycle 10; `busy` and `sm_want` rise the cycle after the dispatch. Meanwhile the driver already writes the next kernel's registers (cycles 9 to 11), which must not affect these launches.

```wave
clk          | pppp
disp_valid   | 1000
reg_wr_en    | 0111
launch_valid | 0110
launch_slot  | x==x| 0 1
occ          | =.==| 0000 0001 0011
busy         | 0111
```

## Files

| File | Role |
|---|---|
| `rtl/05_dispatcher/dispatcher.sv` | the dispatcher; planted bugs `BUG_LIVE_CONFIG`, `BUG_IGNORE_AVAIL`, `BUG_BUSY_EARLY` |
| `dispatcher_transactions.sv`, `dispatcher_sequences.sv` | `disp_kernel`: pc, argument, warps (0..6, so the clamping is tested), workgroup count, and whether the driver rewrites the registers right after DISPATCH |
| `dispatcher_driver.sv` | plays the CP: three register writes, then the DISPATCH handshake |
| `dispatcher_sm_model.sv` | plays the SMs (each workgroup runs a random time, then `wg_done`) and the GMU (SMs randomly sleep and wake) |
| `dispatcher_checker.sv` | cycle-accurate checker and 20 coverage bins |
| `dispatcher_assertions.sv`, `dispatcher_env.sv`, `dispatcher_tests.sv`, `dispatcher_pkg.sv`, `dispatcher_tb_top.sv`, `Makefile` | SVA, wiring, five tests, top |

## Verification decisions and why

**What we check, in one sentence.** Every workgroup of every kernel is launched exactly once, in order, into a free slot of an awake SM, with the configuration that was valid at DISPATCH time, as soon as such a slot exists, and `busy` tells the truth.

| Decision | Why |
|---|---|
| Cycle-accurate checker instead of a transaction scoreboard | The rules are about *when* (a launch must happen in the first cycle a slot is free), not only *what*. |
| **Work-conserving check**: if work waits and a free awake slot exists, a launch must happen this cycle | Catches a dispatcher that stalls or starves slots, which a "right values" check would never notice. |
| The checker does not insist on a particular slot | The spec only requires a free, available slot. Checking the exact round-robin choice would test an implementation detail and break on any legal change. |
| The driver often rewrites the registers right after DISPATCH | The only way to tell latched from live configuration. |
| The SM model never finishes a workgroup in the cycle it is launched | Found the hard way: the first model did, the done pulse was lost, and the test hung. A workgroup cannot end before it starts. |

**Coverage (20 bins) and why.** Workgroup counts 0, 1, fits in the slots, more than the slots (queueing); warps per workgroup 1-4 and both clamping cases; every slot used; waiting because all slots are full vs because an SM is asleep; a done and a launch in the same cycle; a slot reused the very next cycle; a DISPATCH while the previous kernel's workgroups still run; registers written while launching. The first coverage model had a bin "launch into a slot on the cycle its done arrives", which is impossible by design (the slot is still occupied); it was replaced by the two reachable cases.

**Assertions.** `a_busy_after_dispatch` (busy rises the cycle after a DISPATCH with work: the SQE's WAIT_FOR_IDLE settle contract), `a_no_launch_idle`, `a_disp_stable` (driver), `a_no_x`.

## Tests

| Test | Purpose |
|---|---|
| `dispatcher_smoke_test` | 10 small kernels |
| `dispatcher_rand_test` | 150 kernels, up to 12 workgroups, SMs occasionally asleep |
| `dispatcher_full_test` | long workgroups, up to 40 per kernel: slots full most of the time |
| `dispatcher_power_test` | SMs sleep often and wake slowly |
| `dispatcher_short_wg_test` | workgroups of 1-4 cycles: slots freed and reused constantly |

## Results

| Item | Result |
|---|---|
| Regression | 5 tests x 3 seeds = 15 runs, all PASS; up to 1,146 launches per run |
| Merged coverage | 100% (20 of 20 bins) |
| `BUG_LIVE_CONFIG` | caught: `launch config pc=8fb9a150 ..., expected pc=f641a3b8` |
| `BUG_IGNORE_AVAIL` | caught: `launch into slot 0 but SM0 is asleep` |
| `BUG_BUSY_EARLY` | caught: `busy=0 but remaining=0 occupied=1111` |

# Teaching section: the dispatcher in context

## The block and its pins

```pins
block: Dispatcher | dispatcher.sv · 4 slots (2 SMs x 2 sub-cores) · round-robin · 1 launch per cycle
in: reg_wr_en, reg_wr_addr, reg_wr_data | cp_packet_decoder | type 4 writes to 0x100 KERNEL_PC, 0x101 WARPS_PER_WG, 0x102 ARG_BASE
in: disp_valid / disp_ready, disp_num_wg | cp_sqe | DISPATCH: start a kernel with N workgroups / dispatcher is idle
in: wg_done[3:0] | sub-cores of both SMs | a workgroup on that slot has finished
in: sm_avail[1:0] | gmu | the SM is powered and usable
out: launch_valid, launch_slot | SMs | launch one workgroup on this slot (SM = slot % 2, sub-core = slot / 2)
out: launch_wg_id, launch_nwarps, launch_pc, launch_arg | SMs | the workgroup's id, warps, first PC and argument pointer
out: sm_want[1:0] | gmu | this SM is needed (work left to launch, or a workgroup running on it)
out: busy | busy bit 0 | workgroups left to launch, or any slot still occupied
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the system

```hflow
SQE | DISPATCH N -disp-> Dispatcher | splits into workgroups | you -launch-> SM sub-core | runs the warps -wg_done-> Dispatcher | frees the slot
```

The dispatcher is the **bridge between the command processor and the compute cores**. The CP thinks in kernels ("run this program N times"); the SMs think in workgroups ("run these 1 to 4 warps"). The dispatcher hands out workgroup numbers 0, 1, 2 ... N-1 to free sub-cores until all are launched, and keeps track of which slots are still busy.

| Slot | SM | Sub-core |
|---|---|---|
| 0 | 0 | 0 |
| 1 | 1 | 0 |
| 2 | 0 | 1 |
| 3 | 1 | 1 |

The interleaved numbering means consecutive workgroups go to *different* SMs first, which spreads the load and uses both SMs' memory ports early.

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| SQE (03) | disp_* | Starts a kernel. Accept happens only when the dispatcher has nothing left to launch (`remaining == 0`). |
| Packet decoder (01) | reg_wr_* | Writes the next kernel's configuration into the `cfg_*` registers. |
| SMs (15) | launch_* out, wg_done in | In mgpu_top, `launch_slot[0]` picks the SM and `launch_slot[1]` the sub-core. Each sub-core reports `wg_done` when all warps of its workgroup have exited. |
| GMU (21) | sm_avail in, sm_want out | Power management handshake: the dispatcher asks for an SM with `sm_want`; the GMU wakes it and reports `sm_avail` once usable. The dispatcher never launches onto an unavailable SM. |
| mgpu_top | busy, launch_valid | Busy bit 0 (dispatcher plus SMs) for WAIT_FOR_IDLE and the RBBM. `launch_valid` is also a perf event. `disp_valid && disp_ready` invalidates the SM caches at kernel start. |

## Design details

- **Two copies of the configuration.** `cfg_*` is what the type 4 packets write. `k_*` is a copy latched when a DISPATCH is accepted, and it is what the launches use. So the driver can program kernel B while kernel A is still launching, without breaking A.
- **Counters, not a list.** `remaining` counts workgroups still to launch, `next_wg` is the id of the next one. One DISPATCH of 1000 workgroups costs no more storage than one of 4.
- **Occupancy bits.** `occ` has one bit per slot. A launch sets the bit, `wg_done` clears it. A sub-core runs one workgroup at a time, so a slot is either free or busy.
- **Round-robin pick.** The search starts at pointer `rr` and takes the first slot that is free and whose SM is available. After a launch, `rr` moves to the slot after the one picked. This spreads workgroups across slots and avoids always filling slot 0 first.
- **One launch per cycle.** `launch_valid` is a pulse with no ready: the slot is known to be free, so the SM must take it. This is "slot bookkeeping" instead of a handshake.
- **Warps per workgroup clamped.** A value of 0 becomes 1 and anything above 4 becomes 4, because a sub-core has 4 warp slots. The 3-bit field fits 1 to 4.
- **Busy until the last workgroup finishes.** `busy` stays high while there is anything left to launch *or* any slot is occupied. Being done launching is not the same as the kernel being done.

## Questions: what if we did it differently?

**Q1. What if we used fixed priority (always the lowest free slot) instead of round-robin?**
Fixed priority is a simpler priority encoder with no pointer. But slot 0 (SM 0) would always be used first, so with fewer workgroups than slots, SM 1 would sit idle, and the GMU could switch it off while SM 0 does all the work. Round-robin spreads the work. The testbench would change its expected slot sequence and add a load-balance check.

**Q2. What if we chose the least-loaded SM (or the one with most free warps) instead?**
That is *load-aware* scheduling, closer to real GPUs, which pack several workgroups per SM limited by registers, shared memory and warp slots. It needs resource counters per SM and a compare tree. It packs work better when workgroups vary in size. The testbench would need a resource model of each SM and a check that no launch exceeds it.

**Q3. What if several workgroups could share a sub-core?**
With 4 warp slots, two workgroups of 2 warps could run side by side, giving more warps to hide latency. `occ` would become a warp-slot count per sub-core, and `wg_done` would need a workgroup id. The barrier logic in the sub-core would have to separate the two workgroups. The testbench would need tests that mix workgroup sizes.

**Q4. What if `launch_valid` had a ready from the SM (valid/ready) instead of being a pulse?**
A ready would let an SM refuse a launch (for example if it is being flushed). Then the dispatcher would hold the launch until accepted, and its state update would move from "on launch_valid" to "on launch_valid && launch_ready". It costs one wire and one condition, and makes the interface more robust. The testbench would add random backpressure on `launch_ready`.

**Q5. What if the dispatcher could accept the next DISPATCH before the last workgroup of the current one finished?**
It already can: `disp_ready` only needs `remaining == 0`, not idle slots. Kernel B's first workgroups can launch while A's last ones are still running. If you required full idle instead (wait for `occ == 0`), each kernel would end with idle slots (the "tail effect"), but kernels would never overlap, which is simpler to reason about. The driver uses WAIT_FOR_IDLE when it needs that.

**Q6. What breaks with `BUG_IGNORE_AVAIL`?**
The pick ignores `sm_avail`, so a workgroup can be launched onto an SM that the GMU has powered off or is still waking up. That workgroup is lost or corrupted, `occ` stays set, and the kernel never completes, which the RBBM eventually reports as a hang. A test that powers an SM off (sets a GMU idle limit) and then dispatches finds it.

**Q7. What breaks with `BUG_LIVE_CONFIG`?**
Launches use the live `cfg_*` registers instead of the latched copy. If the driver writes the next kernel's PC while the current kernel is still launching, later workgroups of the current kernel start at the wrong program. The test programs a new configuration right after a DISPATCH of many workgroups and checks every launch's PC and argument.

**Q8. What breaks with `BUG_BUSY_EARLY`?**
Busy drops as soon as the last workgroup is *launched*, not when it *finishes*. WAIT_FOR_IDLE then ends too early and the fence fires while workgroups are still running, so the CPU reads incomplete results. The test checks that busy stays high until the last `wg_done`.

**Q9. What if workgroup ids were multi-dimensional (x, y, z)?**
Real APIs (CUDA grids, OpenCL NDRange) use 3D ids. The dispatcher would carry three counters with carries between them, and S2R in the ALU would need three special registers. It changes nothing in hardware capacity; it only makes 2D and 3D problems easier to program. The testbench would check id order across the three dimensions.
