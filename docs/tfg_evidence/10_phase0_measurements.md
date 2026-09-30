# 10 — Phase 0 Measurements (P0-B / P0-C / P0-D)

Measurements that inform the `tbd_from_pilot` slots in `experiment/manifest.yaml`.

> **Nothing in this document sets a parameter.** Every slot in the manifest's
> `tbd_from_pilot` block stays `null` until the user decides. This file reports
> measurements, the range that would be defensible, and a recommendation. The
> recommendation is an input to that decision, not the decision.
>
> Evidence tags: **VERIFIED** (re-checkable now from the tree or an archived log),
> **TO VERIFY**, **TBD FROM PILOT**, **DESIGN DECISION**, **ASSUMED**.

Instrumentation revision used throughout: the periodic soft-timer sampler with the
timing self-check (`gap_min_ticks` / `gap_max_ticks`), `nrtx` activity counters,
`unacked` accounting and the per-sample trace ring. See `08_design_rationale.md`
("The sampling instrument") and `09_sampler_derisk.md`.

---

## P0-C-1 — Sampler validation at 500 ms (G2)

**Status: PASS. The sampler behaves identically at low throughput.** This was the
cell most likely to expose timer irregularity (low throughput, less lock
contention, longer run for the same sample count), and it did not.

Conditions: `L0` = 8196/44/44 (boot-banner-confirmed), `netem delay 500ms`
(wrapper-applied and `tc`-verified), interval 100 ms, tier `full`, 64.8 s run,
RT-Thread→Ubuntu, GNU iperf 2.1.9 host receiver in CSV mode.

Host ping immediately before: min 500.751 / avg 564.152 / max 1005.863 /
mdev 166.950 ms, n=8, 0% loss. **VERIFIED.** Note the avg and max exceed the
configured 500 ms and mdev is large; `ping` reported `pipe 2`, i.e. more than one
probe in flight. This is a property of measuring a 500 ms path with 0.8 s spacing,
not evidence of netem misbehaviour — qdisc counters showed 0 dropped / 0 overlimits
/ 0 requeues / 0 backlog before and after. **TO VERIFY** whether a spaced-out ping
series reproduces a tighter distribution; it does not affect the sampler result.

| Quantity | Value | Tag |
|---|---|---|
| `sample_count` | 647 | VERIFIED |
| `sample_span_ticks` | 6460 (= 64.60 s at `RT_TICK_PER_SECOND`=100) | VERIFIED |
| Expected count = span/interval + 1 | 6460/10 + 1 = **647** | VERIFIED |
| Count vs expected | **exact, zero drift** | VERIFIED |
| `gap_min_ticks` / `gap_max_ticks` | **10 / 10** — every inter-sample gap was exactly the nominal 10 ticks | VERIFIED |
| `stale_count` | 0 | VERIFIED |
| `nrtx_max`, `nrtx_nonzero_count` | 0, 0 | VERIFIED |
| `snd_queuelen_max` ≤ `TCP_SND_QUEUELEN` | 12 ≤ 44 — PASS | VERIFIED |
| `inflight_max` ≤ `snd_wnd_max` | 8196 ≤ 65535 — PASS | VERIFIED |
| Host throughput | 1 056 764 bytes / 64.8 s = **130 465 bit/s** | VERIFIED |

Compared against the 50 ms validation run (`09_sampler_derisk.md`, `val01`):
319/319 samples, `gap` 10/10. **The timing self-check is exact at both ends of the
RTT range**, at a ~9.5× throughput ratio. No drift appeared at 500 ms, so the
sampling design does not need changing on this evidence.

### Two substantive by-products of this run

1. **The FULL tier does produce non-zero output.** `unsent_nonempty_count` = 5 of
   647 samples (0.77%), `unsent_bytes_max` = 4100. Across all 11 de-risking runs at
   50 ms it had been 0, which left open whether FLOOR was sufficient everywhere.
   It is not sufficient at 500 ms. **VERIFIED** at L0/500 ms; see P0-C-3 for the
   ladder × RTT sweep.
2. **`unacked` accounting was added and is immediately informative.**
   `unacked_nonempty_count` = 647 of 647, `unacked_bytes_max` = 8196 = exactly
   `TCP_SND_BUF`, while `snd_buf_max` = **4 bytes** and `snd_buf_mean_x1000` = 18
   (i.e. a mean of 0.018 free bytes). The same pattern holds at 50 ms
   (`snd_buf_max` = 540, `unacked_bytes_max` = 8196). Reported as observed;
   mechanism attribution is Phase 1's job, not this document's.

---

## P0-C-2 — Run-to-run variance and tier perturbation at 50 ms (G3a)

Conditions: `L0`, `netem delay 50ms` (`tc`-verified), interval 100 ms, 20 s runs,
**8 cycles of OFF→FLOOR→FULL interleaved inside a single boot** (24 runs), host
receiver in `-y C` CSV mode so throughput is a full-precision integer bit/s rather
than the 3-significant-figure human format. Raw: `raw_logs/p0c_g3a_*`.

### Timing self-check: 24 / 24 exact

Every run's `sample_count` equalled `sample_span_ticks / interval_ticks + 1`
exactly. `gap_min = gap_max = 10` ticks in 23 of 24 runs; one run (`g3a_6_full`)
had `gap_max = 11`, i.e. a single inter-sample gap one tick long. `stale_count` was
0 and `nrtx_max` was 0 in all 24. **VERIFIED.**

### Throughput by tier — all runs

| Tier | n | mean bit/s | SD | CV | min … max |
|---|---|---|---|---|---|
| OFF | 8 | 1 245 034 | 3 450 | **0.277 %** | 1 239 815 … 1 249 153 |
| FLOOR | 8 | 1 238 066 | 10 592 | 0.855 % | 1 215 430 … 1 249 196 |
| FULL | 8 | 1 234 111 | 29 144 | 2.362 % | 1 162 558 … 1 247 297 |

Taken at face value this shows FLOOR −0.56 % and FULL −0.88 % against OFF, and the
FULL deficit is ~3× the OFF standard deviation. **That reading is wrong, and the
per-interval data shows why.**

### Why: two runs contain localized throughput collapses

The per-second interval series (`intervals.py`) shows the steady rate is
1 245 792 bit/s, hit almost every interval in almost every run. Two runs deviate,
and neither deviation has the shape of a sampling cost:

- `g3a_4_floor` — flat at 1 245 792 through interval 16, then **887 552** and
  **983 520** at intervals 17–18, then recovers to normal for the rest.
- `g3a_6_full` — flat through interval 17, then **1 037 760 / 720 800 / 580 544 /
  840 985** over the final four intervals. This is the same run that carried the
  lone `gap_max = 11` and a short `sample_span`, i.e. the disturbance touched the
  guest's timing as well as its throughput.

A per-sample cost would depress throughput uniformly across the run. A collapse
confined to a 2–4 s window, with full-rate intervals either side, is a
host/QEMU-side disturbance. **VERIFIED** (the shape is directly visible in the
archived per-interval CSV); the *cause* is **TO VERIFY**.

### Robust statistics

| Tier | median (all 8) | mean excl. the 2 disturbed runs | SD | CV |
|---|---|---|---|---|
| OFF | 1 245 532 | 1 245 034 (n=8) | 3 450 | 0.277 % |
| FLOOR | 1 240 669 | 1 241 289 (n=7) | 5 828 | 0.470 % |
| FULL | 1 245 506 | 1 244 364 (n=7) | 3 137 | 0.252 % |

All three tiers now agree to within 0.3 %, and the largest gap (FLOOR, −0.30 %) is
about one OFF standard deviation.

**A consistency argument that does not depend on excluding anything:** in the
all-runs means, FULL is *lower* than FLOOR. FULL does strictly more work per sample
than FLOOR — it additionally walks the `unsent` and `unacked` segment lists — so a
genuine sampling cost cannot produce FULL < FLOOR. The ordering being physically
impossible is direct evidence that the tier differences in the all-runs table are
noise, not cost. **VERIFIED.**

> **Stop-condition check.** The brief says to stop and report if perturbation at
> FLOOR exceeds run-to-run variance. On the all-runs means it appears to
> (−0.56 % against an OFF CV of 0.277 %); on medians, on outlier-excluded means,
> and on the FULL-below-FLOOR consistency argument it does not. **Reported, not
> worked around.** Post-hoc exclusion of two runs is a judgement call and is
> flagged as such — the honest statement is that no perturbation is detectable at
> this sample size once two identifiable disturbances are accounted for, and that
> the disturbances themselves are the larger threat to the dataset.

### Run-to-run variance estimate

The cleanest available estimate is the OFF arm, which carries no sampling at all:
**SD ≈ 3 450 bit/s, CV ≈ 0.28 %**, n=8, at L0/50 ms over 20 s runs. **VERIFIED**
for this cell only; **ASSUMED** — and untested — that CV is comparable at other RTT
points and ladder points. The 500 ms cell is the obvious place for it to differ,
since the same 20 s run there contains ~9.5× fewer bytes.

### Transient onset at 50 ms: there is essentially none

A by-product of the per-interval data, and the first half of G4's question. The
steady rate 1 245 792 bit/s is reached in the **first or second 1-second interval**
in every one of the 24 runs; interval 0 is typically 1 212 000 – 1 278 000 and
interval 1 onward is at rate. Dropping the first T seconds (T = 0…10) does not
reduce the group SD — it *increases* it, because shorter remaining windows are more
exposed to the localized collapses above. **VERIFIED for L0/50 ms.**

Consequence for the discard interval: at this cell a discard window is not needed
and a large one is actively harmful. Whether that holds at 200/500 ms is
**TO VERIFY** — untested, and the reason G4 exists.

---

## P0-C-3 — Sampling interval sweep (G3b)

Conditions: `L0`, `netem delay 50ms` (`tc`-verified), 20 s runs, **5 cycles of
OFF(100 ms) → FULL at 10 / 20 / 50 / 100 / 500 ms, interleaved inside a single
boot** (30 runs). Lower bound on the interval is one system tick = 10 ms
(`RT_TICK_PER_SECOND` = 100), so 10 ms is the finest the platform can express.

### Timing self-check across the whole interval range: 30 / 30 exact

| Interval | Nominal ticks | `gap_min` / `gap_max` observed | samples / 20 s | count vs expected |
|---|---|---|---|---|
| 10 ms | 1 | **1 / 1** | 2181 – 2199 | exact |
| 20 ms | 2 | **2 / 2** | 1089 – 1098 | exact |
| 50 ms | 5 | 5 / **6** | 423 – 439 | exact |
| 100 ms | 10 | 10 / 10 | ~219 | exact |
| 500 ms | 50 | **50 / 50** | 34 – 43 | exact |

`stale_count` = 0 and `nrtx_max` = 0 in all 30. **VERIFIED.** The timer holds its
period exactly even at a 1-tick interval, i.e. firing on every single system tick.
The one deviation is at 50 ms, where occasional gaps were 6 ticks instead of 5;
`sample_count` still matched `span/interval + 1` exactly, so this is jitter in
*which* tick a sample lands on, not a lost or extra sample.

### Throughput by interval

| Arm | n | mean bit/s | SD | CV | median | Δ median vs OFF |
|---|---|---|---|---|---|---|
| OFF (100 ms) | 5 | 1 233 419 | 18 663 | 1.513 % | 1 237 545 | — |
| FULL 10 ms | 5 | 1 241 519 | 7 786 | 0.627 % | 1 245 656 | **+0.655 %** |
| FULL 20 ms | 5 | 1 242 920 | 6 488 | 0.522 % | 1 246 770 | **+0.745 %** |
| FULL 50 ms | 5 | 1 228 275 | 20 431 | 1.663 % | 1 233 500 | −0.327 % |
| FULL 100 ms | 5 | 1 246 202 | 4 971 | 0.399 % | 1 245 935 | **+0.678 %** |
| FULL 500 ms | 5 | 1 195 202 | 104 620 | 8.753 % | 1 241 974 | **+0.358 %** |

**Four of the five sampled arms are FASTER than the unsampled arm on medians**, and
the full spread of medians across all six arms is 1.1 %. A sampling cost cannot make
a run faster, so the correct reading is that the sampling effect is below the noise
floor over the entire 10 – 500 ms range, not that it is negative.

The mean column is the less trustworthy one, and the disturbed runs are individually
visible in the per-run series: `off100` has one run at 1 201 787, `full50` has two at
1 197 486 and 1 219 535, `full500` one at 1 008 103. Those four runs account for the
whole pattern in the means — `full500`'s mean of 1 195 202 sits 47 000 below its own
median of 1 241 974. With n=5, one collapse moves an arm mean further than any
plausible per-sample cost.

The ordering is also anti-correlated with cost: the *finest* interval (10 ms, ~2190
samples per run, i.e. firing on every system tick) has a **lower** CV than the
unsampled OFF arm, and the *coarsest* (500 ms, ~38 samples) has the highest. Sampling
57× more often cannot cost less and vary less.

**Conclusion: no sampling interval in 10 – 500 ms produces a throughput effect
distinguishable from run-to-run variance at n=5.** The stop-condition "no sampling
interval satisfies both perturbation and resolution" is **not** met — the
perturbation side of the trade-off is unmeasurably small across the whole range,
which makes the choice a resolution question almost exclusively.

### Resolution side of the trade-off — this is where the interval matters

The interval does not visibly change throughput, but it strongly changes **what the
sampler sees**. Three independent resolution proxies, all monotone in sampling rate:

| Arm | `unsent_nonempty_count` per run | `snd_buf_max` observed (bytes) | `snd_buf_mean_x1000` range |
|---|---|---|---|
| FULL 10 ms | **5** (every run) | 2940 – 4508 | 4 600 – 12 970 |
| FULL 20 ms | 2 – 3 | 1124 – 2968 | 3 802 – 7 354 |
| FULL 50 ms | 1 | 576 – 4248 | 1 473 – 43 328 |
| FULL 100 ms | **0** | 0 – 2924 | 0 – 19 214 |
| FULL 500 ms | **0** | 4 – 2944 | 186 – 68 465 |

**VERIFIED.** The `unsent` column is the sharp result. `unsent` is non-empty only
briefly, and whether the sampler ever catches it is decided by the interval: at
10 ms it is caught in every run, at 100 ms and 500 ms it is never caught at this
cell. Whenever it was caught, `unsent_bytes_max` was **4100**, consistently, across
10/20/50 ms. (4100 against an `IPERF_BUFSZ` of 4096 is noted, not explained;
**TO VERIFY** what the extra 4 bytes are.)

This settles the FLOOR-vs-FULL question from the brief in a way the earlier runs
could not: **FULL does produce non-zero output, but only if the interval is fine
enough to catch a short-lived state.** At 100 ms the FULL tier at this cell returns
exactly what FLOOR would. So "is FLOOR sufficient?" is not a property of the tier —
it is a joint property of the tier and the interval. **TO VERIFY** across the
ladder and the other RTT points (that was G3c/G4; not run).

Note also that at the 500 ms interval `snd_buf_max` reached only 4 bytes in one run
while the 10 ms arm consistently saw ~3000–4500: a coarse sampler reports the send
buffer as permanently full, a fine one reports brief refill excursions. The two
would support different mechanism verdicts from the same underlying behaviour. That
is the strongest argument in this section for treating the interval as an
evidence-quality decision rather than an overhead decision.
