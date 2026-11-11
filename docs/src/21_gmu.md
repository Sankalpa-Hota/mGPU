# 21 GMU (power management)

## What this block is, in plain words

An idle SM still burns power. The GMU switches an SM off when it has had nothing to do for a while, and back on when the dispatcher needs it. Waking takes a few cycles (power and clock must settle), so the dispatcher is told an SM is usable only once it is fully on.

## State machine (per SM)

```flow
box: ON | available; counts consecutive cycles with the SM not busy and not wanted
arrow: idle for idle_limit cycles
box: OFF | power gated, not available | hw
arrow: dispatcher wants the SM
box: WAKING | powered, not yet available, for 6 cycles | ok
back: back to ON
```

## RTL decisions and why

| Decision | Why |
|---|---|
| Never power off a busy SM | It would lose running work (`BUG_OFF_WHILE_BUSY`). |
| The idle count restarts on any busy cycle or any "want" | Gating must follow **consecutive** idle time (`BUG_IDLE_NO_RESET` only pauses the count, so short idle periods add up and the SM is gated too early). |
| Available only in ON, not while WAKING | Work launched on a half-powered SM would be lost (`BUG_AVAIL_EARLY`). |
| `idle_limit = 0` disables gating | A safe default at boot. |

## Verification decisions and why

| Decision | Why |
|---|---|
| A workload model plays dispatcher and SMs: work arrives at random, the dispatcher wants an SM while it has work for it, starts a job only on an available SM one cycle after wanting it | The same causality as the real chip; the first model launched in the same cycle and made one coverage bin unreachable. |
| Cycle-accurate model of both state machines | Gating time and wake latency are checked to the cycle. |
| Liveness at the end: all queued work must run | An SM that never wakes would leave work pending forever. |

## Results

| Item | Result |
|---|---|
| Regression | 4 tests x 3 seeds = 12 runs, all PASS (about 600 to 1,000 power-off / wake-up cycles per long run) |
| Merged coverage | 100% (12 of 12) |
| `BUG_OFF_WHILE_BUSY`, `BUG_AVAIL_EARLY`, `BUG_IDLE_NO_RESET` | all caught by the cycle model (and the busy-while-off assertion) |

# Teaching section: the GMU in context

## The block and its pins

```pins
block: GMU | gmu.sv · per-SM power FSM (ON, OFF, WAKING) · NSM = 2 · WAKE_CYCLES = 6
in: idle_limit[15:0] | control register 0x204 | idle cycles before an SM is switched off; 0 = never switch off
in: sm_busy[NSM] | SMs | the SM has work in flight
in: sm_want[NSM] | dispatcher | the dispatcher wants to launch a workgroup on this SM
out: sm_avail[NSM] | dispatcher | the SM is ON and may receive a launch
out: sm_power[NSM] | power switch (and waveforms) | the SM's power is on (ON or WAKING)
out: stat_off_pulse, stat_wake_pulse | RBBM perf counters | one-cycle pulses: an SM was switched off / started waking
```

Read it like a chip pinout: inputs are on the left, outputs on the right. A valid/ready pair is drawn on the side of its `valid` signal; `ready` always flows the other way. The orange name over each pin is the block on the other end of the wire.

## Where it sits in the system

```hflow
SQE | DISPATCH command -num workgroups-> Dispatcher | picks a free slot -sm_want-> GMU | power control | you -sm_avail-> Dispatcher | launches -launch-> SMs | run workgroups
```

The GMU is a small **power manager** beside the dispatcher. It watches each SM and decides whether it should be powered. The dispatcher asks for an SM (`sm_want`) and may only launch on it when the GMU says it is available (`sm_avail`).

| State | sm_power | sm_avail | Leaves when |
|---|---|---|---|
| ON | 1 | 1 | `idle_limit` consecutive cycles not busy and not wanted (and idle_limit is not 0) go to OFF |
| OFF | 0 | 0 | `sm_want` goes to WAKING |
| WAKING | 1 | 0 | `WAKE_CYCLES` cycles have passed, go to ON |

## Who uses it and for what

| Who | Through which pins | What for |
|---|---|---|
| Dispatcher (14) | sm_want out of it, sm_avail into it | Requests SMs and only launches on available ones. |
| SMs (16) | sm_busy | Report activity so a busy SM is never switched off. |
| Control register 0x204 | idle_limit | Software chooses how aggressive power gating is; reset value 0 means always on. |
| RBBM perf counters | stat_off_pulse, stat_wake_pulse (OR-ed over SMs) | Count power-off and wake events. |
| mgpu_top | sm_power | Produced for observation; in this model the SM is not actually cut off, but the protocol behaves as if it were. |

## Design details

- **Per-SM FSM with a counter.** Each SM has a 2-bit state, a 16-bit idle counter and a 4-bit wake counter. They are fully independent: one SM can sleep while the other runs.
- **Idle means truly idle.** The idle counter is reset to zero in any cycle where the SM is busy or wanted. Only an unbroken run of `idle_limit` quiet cycles switches it off. This is a *hysteresis timer*: it prevents switching off during short gaps between workgroups.
- **Never off while busy.** Because busy resets the counter, an SM with work in flight cannot reach OFF.
- **Waking is not ON.** In WAKING power is already on (`sm_power = 1`) but the SM is not available (`sm_avail = 0`) for `WAKE_CYCLES` cycles. This models the time for the power rail to settle and the clock to start; launching into an SM during that window would be unsafe.
- **Why 16 and 4 bits.** 16 bits allow idle limits up to 65535 cycles, enough for any test. The wake counter only needs to count to `WAKE_CYCLES` (6), so 4 bits.
- **Safe default.** Reset puts every SM ON and `idle_limit` is 0, so gating is off until software turns it on.

## Questions: what if we did it differently?

**Q1. Clock gating versus power gating versus DVFS?**
*Clock gating* stops the clock to an idle SM: it saves dynamic power only, wakes in one cycle, and keeps all state. *Power gating* (what the GMU models) cuts the supply: it also removes leakage, but state is lost and waking takes many cycles. *DVFS* (dynamic voltage and frequency scaling) runs the SM slower at a lower voltage instead of switching it off: it suits steady partial load, but needs voltage regulators, a clock generator that can change frequency, and clock-domain crossings. Real GPUs use all three: clock gating at fine grain, power gating for long idles, DVFS for the whole chip.

**Q2. What if `idle_limit` were very small, or a fixed constant?**
A tiny limit turns SMs off in every short gap, and then every new workgroup pays the wake time; the energy to switch can exceed the savings (break-even time). A fixed constant cannot adapt to workload. That is why it is a register. Smarter alternatives: an adaptive timer that grows when an SM is woken soon after sleeping, or a predictor based on the queued work in the command stream.

**Q3. What if waking were instant (WAKE_CYCLES = 0)?**
Then WAKING would be pointless and sm_avail could follow sm_want immediately. That is only realistic for clock gating. With real power gating, rush current on wake can drop the supply for neighbours, so real designs even stage the wake (turn on the power switches in groups), making it longer, not shorter.

**Q4. Per-SM gating versus gating the whole GPU at once?**
Per-SM (ours) keeps one SM running for a small kernel while the other sleeps. Whole-GPU gating is simpler and saves the most when the GPU is fully idle, but it would also need to save and restore the command processor state. Finer than per-SM (per sub-core or per unit) gives more savings with more control logic and more isolation cells.

**Q5. What does state retention change?**
Power gating loses register and cache contents. Our SM caches are invalidated at kernel start anyway, so nothing is lost that matters. A design that keeps state across sleep needs *retention flip-flops* (a small always-on latch per flop) or a save/restore sequence to memory, both of which cost area or wake time.

**Q6. What does `BUG_AVAIL_EARLY` break?**
`sm_avail` becomes true in WAKING as well as ON. The dispatcher may launch a workgroup into an SM whose power and clock are not yet stable. In this RTL the SM is not truly unpowered, so the data may still be right, but the protocol check fails: a launch is seen while the SM is in WAKING. The bench catches it with an assertion "launch implies state ON".

**Q7. What do `BUG_OFF_WHILE_BUSY` and `BUG_IDLE_NO_RESET` break?**
`BUG_OFF_WHILE_BUSY` ignores `sm_busy` in the counter, so an SM running a long workgroup without new launches counts up and is switched off in the middle of its work: a correctness disaster in real silicon. `BUG_IDLE_NO_RESET` pauses the counter while busy instead of clearing it, so quiet time before and after a busy period adds up; the SM switches off sooner than `idle_limit` quiet cycles. Tests must produce idle gaps that are each shorter than the limit but add up to more than it.

**Q8. Who should decide, hardware or software?**
Our GMU is a hardware policy with a software knob. Fully software-controlled gating (the driver writes "SM1 off") gives the driver more knowledge of upcoming work but reacts slowly. Hardware reacts in cycles but only sees local signals. Real GPUs combine a firmware microcontroller (power management unit) with hardware timers.
