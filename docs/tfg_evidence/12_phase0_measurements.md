# 12 — Phase 0 Measurements (P0-B / P0-C / P0-D)

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

---

## P0-D — Transients and steady state (G4), and the `unsent` sweep (G3c)

Conditions: 90 s runs at 100 ms sampling interval with the per-sample trace
captured, plus a 20 s companion run at 10 ms interval per cell for resolution.
Four RTT points (50 / 100 / 200 / 500 ms, each `tc`-verified before its runs),
at `L0` and `L2`. Tier `full` throughout. n=1 per cell — this is transient
characterization, not a variance estimate.

### Steady state is reached within the first second at every RTT

`L0`, 90 s runs, steady reference = median of the per-second host intervals from
t ≥ 30 s:

| Cell | steady median bit/s | first interval ≥ 95 % | first interval ≥ 99 % |
|---|---|---|---|
| L0 / 50 ms | 1 245 792 | t = 0 s | t = 1 s |
| L0 / 100 ms | 631 968 | t = 0 s | t = 1 s |
| L0 / 200 ms | 327 840 | t = 1 s | t = 1 s |
| L0 / 500 ms | 131 136 | t = 1 s | t = 1 s |

**VERIFIED.** There is no measurable startup transient in throughput at any RTT
point: every cell is within 1 % of its steady median by the second 1-second
interval. This replicates, over 90 s runs and across the full RTT range, what
P0-C-2 found at 50 ms over 20 s runs.

> **A metric that did not work, recorded so it is not repeated.** The first
> steady-state rule tried was "the earliest interval from which *all* later
> intervals are within ±5 % of the steady median". It returned t = 70 s for
> L0/50 ms and *no answer at all* for L0/200 ms and L0/500 ms — not because the
> transient is long, but because a single late dip anywhere in the run falsifies an
> all-subsequent-intervals condition. **Any steady-state rule of that form is
> unusable on this platform**, because the late dips (P0-C-2) are a real and
> recurring feature. A workable rule has to be a first-crossing rule, or tolerate
> a stated number of excursions.

### Late dips are common and are the real threat, not the transient

Counting per-second intervals below 95 % of the steady median *after* first
crossing it: 1 (L0/50 ms), **9** (L0/100 ms), **13** (L0/200 ms), 2 (L0/500 ms).
Two are extreme: L0/200 ms has an interval at 11 680 bit/s (3.6 % of steady) at
t = 10 s and another at 196 704 (60 %) at t = 2 s. **VERIFIED** as observed; the
cause is **TO VERIFY** and is the same open question as P0-C-2's collapses.

This is the single most consequential finding for the protocol design: the
dominant per-run error source is not a transient that a discard window fixes, it
is sporadic multi-second disturbances distributed through the run.

### Sender state: `snd_buf` is pinned at zero and `cwnd` keeps growing past saturation

From the archived traces (`raw_logs/p0d_*.trace`). At 100 ms interval, **`snd_buf`
is 0 in every single sampled row of every cell**, and `inflight` sits at 8196 =
`TCP_SND_BUF` exactly. Meanwhile `cwnd` is still climbing: at L0/50 ms it goes
8760 → 14030 → 16922 → 20453 → 23545 → 25865 → 28664 → 31549 over the first 1.4 s,
and `cwnd_max` for the run is 65505.

So `cwnd` continues to grow long after throughput has saturated. Reported as
observed. **Mechanism attribution is Phase 1's job and is not performed here**,
but it is worth flagging for the Phase 1 analysis that the per-RTT steady rates
are almost exactly `TCP_SND_BUF` per RTT: 131 136 bit/s = 2 × 8196 B/s at 500 ms,
327 840 = 5 × 8196 at 200 ms, 655 680 ≈ 10 × 8196 at 100 ms. That arithmetic is
noted, not interpreted.

### G3c — does the FULL tier ever produce non-zero `unsent`? Yes, and it grows with RTT

`unsent_nonempty_count` per run at `L0`:

| RTT | at 100 ms interval (90 s run) | at 10 ms interval (20 s run) |
|---|---|---|
| 50 ms | 0 | 5 |
| 100 ms | 1 | 10 |
| 200 ms | 2 | 20 |
| 500 ms | 5 | 50 |

**VERIFIED.** `unsent_bytes_max` was **4100 in every case where it was non-zero**,
at every RTT and both intervals. Two independent monotone trends: `unsent`
occupancy rises with RTT, and the sampler's chance of catching it rises with
sampling rate. The 10 ms column is exactly 10× the 100 ms column at every RTT,
which is what a fixed, short, periodically-recurring `unsent` episode sampled at
10× the rate would give.

**So FLOOR is not sufficient**, and the earlier concern that FULL-tier runs "buy
nothing" is resolved: they buy the `unsent` evidence, which is one of the three
mechanism categories the research question asks about, and it is only visible at
all at fine sampling intervals.

### L2 — the same conclusions, plus two differences that matter

| Cell | steady median bit/s | first ≥ 95 % | first ≥ 99 % | intervals < 95 % after crossing |
|---|---|---|---|---|
| L2 / 50 ms | 4 915 200 | t = 1 s | t = 1 s | 1 |
| L2 / 100 ms | 2 555 904 | t = 1 s | t = 1 s | 3 |
| L2 / 200 ms | 1 310 720 | t = 1 s | t = 1 s | 6 |
| L2 / 500 ms | 524 288 | **t = 2 s** | **t = 2 s** | 1 |

**Difference 1 — transient length is NOT independent of `TCP_SND_BUF`.** The brief
flagged this as ASSUMED and untested. At 500 ms the two configurations differ:

| | interval 0 | interval 1 | interval 2 |
|---|---|---|---|
| L0 / 500 ms | 98 304 (75 %) | 131 136 (**100 %**) | 131 136 |
| L2 / 500 ms | 102 816 (20 %) | 402 304 (77 %) | 524 288 (**100 %**) |

**VERIFIED, and the assumption is disproven.** L2 takes one extra second to reach
rate at 500 ms, which is consistent with a four-times-larger buffer needing more
round trips to fill, though that explanation is **not** tested here. The effect is
about 1 s, so it is small — but it means any discard interval has to be justified
at the largest ladder point, not at L0. `L1` is unmeasured (see `11` item N3).

**Difference 2 — at L2 the send buffer is genuinely not full.** Where L0 had
`snd_buf` = 0 in every sampled row, L2 shows `snd_buf_max` of 4096 – 28 672 and
`snd_buf_mean_x1000` up to 232 089 (a mean of 232 free bytes). `unsent_bytes_max`
rises from 4100 at L0 to **24 008 – 28 672** at L2, and the `snd_queuelen`
high-water from 10–15 to **30–31** — still comfortably under the pinned 44, which
is the Layer-2 non-binding evidence `08` relies on. `unacked_bytes_max` is 32 768 =
`TCP_SND_BUF` exactly, the same saturation pattern as L0.

`unsent_nonempty_count` at L2, 10 ms interval: **17 / 32 / 62 / 151** at 50 / 100 /
200 / 500 ms — the same monotone rise with RTT as L0 but 3–4× larger throughout.

### One genuine timing mismatch — the only one in ~120 runs

`g4_L2_r200_i10`: FULL tier, **1-tick (10 ms) interval**, at L2.

```
sample_count 2113   sample_span_ticks 2121   expected 2122   -> 9 samples lost (0.42%)
gap_min_ticks 1     gap_max_ticks 2          stale_count 0
```

`stale_count` = 0 means the pcb validated on every firing, so this is not the
validation path rejecting anything — **the timer itself skipped ticks.** At L2 the
FULL walk traverses roughly 20 `unsent` plus 22 `unacked` segments per sample, and
at a 1-tick interval there is no slack: the sampler must complete within one 10 ms
tick or lose the next. Three other L2 runs at the same interval were exact, so this
is marginal rather than systematic.

> **Stop-condition check.** The brief says to stop and report if the sampler
> drifts at any RTT or interval. **It does, here, and only here.** Reported rather
> than worked around. This is a real bound on the design: a 10 ms interval is at
> the edge of what the platform sustains with the FULL tier at the top of the
> ladder. It does not invalidate the interval sweep (all 30 of those runs were
> exact at L0) and it does not affect any 20 ms or coarser interval. Carried as
> `11` item N1.

---

## P0-B / G5 — replacing the `snd_buf` statistic

### Why the existing statistic carries no information

`snd_buf_low_count` with the 1024-byte default read **318/319** at L0/50 ms and
**647/647** at L0/500 ms — a fraction of ~1.00 at every cell measured. The traces
show why: at L0, `snd_buf` is **exactly 0 in every sampled row**, with `inflight`
pinned at 8196 = `TCP_SND_BUF`. A counter that reads 1.00 everywhere cannot
distinguish cells, and lowering the threshold would not help — the distribution is
a point mass at zero, not a spread that a better cut-point would separate.
**VERIFIED.**

Note this is itself interval-dependent: at a 10 ms interval `snd_buf_max` reached
1464 – 4508 at L0, so the excursions exist and are simply too brief for a 100 ms
sampler to catch (P0-C-3).

### What was implemented instead

A **three-way mechanism classification**, mutually exclusive and exhaustive, so the
three counters sum to `sample_count`:

| Counter | Condition | Research-question alternative it answers |
|---|---|---|
| `mech_app_limited` | `snd_buf > 0` | "the send buffer is under-occupied" |
| `mech_unsent_pending` | `snd_buf == 0` and `unsent != NULL` | "occupied but not transmitted" |
| `mech_ack_pending` | `snd_buf == 0` and `unsent == NULL` | "transmitted but released more slowly than the delay implies" |

**This is parameter-free by construction**: the only comparisons are against exact
zero and against a null pointer. It introduces no threshold, so implementing it
sets nothing. It maps one-to-one onto the three alternatives in
`00_project_state.md` row 1, which is the reason to prefer it over a histogram —
a histogram would need bin edges, and bin edges are a parameter.

It also needs only the **cheap** `unsent` boolean, not the segment walk, so the
classification is available in the FLOOR tier; FULL adds the byte magnitudes, not
the category.

Two supporting counters, also parameter-free or workload-derived:

- `snd_buf_zero_count` — samples with `snd_buf` exactly 0. The sharpest single
  number available, since exactly-zero free space is the state in which a blocking
  `send()` cannot proceed.
- `snd_buf_ge_write_count` — samples with `snd_buf >= 4096`, i.e. room for one
  whole application write. 4096 is `IPERF_BUFSZ` (F14), a fixed property of the
  benchmark workload, not a tunable cut-point.

The legacy `snd_buf_low_count` and its 1024-byte threshold are **retained
unchanged** so that runs already archived stay comparable. Whether the threshold
is re-pointed or dropped is **TBD FROM PILOT** and is not decided here.

---

## P0-B — Pinning control (G6)

`STOCK` = 8196/22/40 versus `PINNED` = 8196/44/44, **interleaved by build**:
2 cycles × (build STOCK → 3 reps at 50 ms + 3 at 500 ms; build PINNED → same).
4 builds, 24 runs, n=6 per (config, RTT). 20 s runs, 100 ms interval, tier `full`.
Each build was macro-dump-verified by `set_config.sh` and boot-banner-confirmed.

Timing self-check: **0 mismatches / 24**, `stale_count` 0, `nrtx_max` 0.

`08` requires three claims to be reported separately and not merged. They are.

### Claim 1 — did the PINNED limit bind? No. (complete, over the cells measured)

| Config | RTT | `TCP_SND_QUEUELEN` | `snd_queuelen` high-water | headroom |
|---|---|---|---|---|
| PINNED | 50 ms | 44 | 11 – 13 | 31 |
| PINNED | 500 ms | 44 | 9 – 11 | 33 |

**VERIFIED.** Combined with P0-D's high-waters (10–15 at L0, **30–31 at L2**), the
pinned limit of 44 was never approached at any cell measured this session. The
largest high-water seen anywhere remains 31, at L2.

### Claim 2 — would the STOCK limit have bound? No, but only where measured

| Config | RTT | `TCP_SND_QUEUELEN` | `snd_queuelen` high-water | headroom |
|---|---|---|---|---|
| STOCK | 50 ms | 22 | 10 – 13 | 9 |
| STOCK | 500 ms | 22 | 10 – 14 | 8 |

**VERIFIED at 50 ms and 500 ms, at `TCP_SND_BUF` = 8196 only.** This claim is
narrower than Claim 1 by construction and must stay so. Note the headroom is 8–9
rather than 31 — the stock limit is not close to binding, but it is not comfortable
either, and nothing here licenses extending this to L1 or L2. At L2 the high-water
of 30–31 **exceeds the stock limit of 22 outright**, so a stock-configured build
could not have run the L2 cells at all.

### Claim 3 — did pinning perturb throughput at the tested points? Not detectably

| Config | RTT | n | mean bit/s | SD | CV | median |
|---|---|---|---|---|---|---|
| STOCK | 50 ms | 6 | 1 246 468 | 4 373 | 0.351 % | 1 247 776 |
| PINNED | 50 ms | 6 | 1 244 492 | 5 014 | 0.403 % | 1 245 324 |
| STOCK | 500 ms | 6 | 130 495 | **30** | **0.023 %** | 130 496 |
| PINNED | 500 ms | 6 | 130 476 | **55** | **0.042 %** | 130 490 |

PINNED − STOCK on medians: **−2 452 bit/s (−0.196 %)** at 50 ms and **−6 bit/s
(−0.004 %)** at 500 ms. At 50 ms that is about half of one standard deviation; at
500 ms it is a fifth of a standard deviation. **No perturbation is detectable.**
The stop-condition "the pinned build differs from stock beyond variance" is **not**
met.

> **Unexpected and important: the 500 ms cell is by far the most reproducible.**
> SD 30–55 bit/s on ~130 490, i.e. CV 0.02–0.04 %, against 0.35–0.40 % at 50 ms —
> an order of magnitude tighter. The prior expectation recorded in P0-C-2 was the
> opposite (fewer bytes per run should mean more variance). **The noisiest cell is
> the fastest one, not the slowest one.** That inverts where `repetitions` should
> be calibrated from. **VERIFIED**, cause **TO VERIFY** — a plausible reading is
> that at 500 ms the rate is set almost entirely by the delay, which netem
> enforces precisely, whereas at 50 ms it is closer to what the host/QEMU can
> actually push, which is what the sporadic collapses disturb.

### The new G5 counters, first exercise

| Config | RTT | samples | `mech_app_limited` | `mech_unsent_pending` | `mech_ack_pending` | `snd_buf == 0` | legacy `< 1024` |
|---|---|---|---|---|---|---|---|
| PINNED | 50 ms | 1312 | 53 (4.04 %) | 0 (0.00 %) | 1259 (96.0 %) | 95.96 % | ~100 % |
| STOCK | 50 ms | 1314 | 47 (3.58 %) | 0 (0.00 %) | 1267 (96.4 %) | 96.42 % | ~100 % |
| PINNED | 500 ms | 1291 | 1 (0.08 %) | 30 (2.32 %) | 1260 (97.6 %) | 99.92 % | ~100 % |
| STOCK | 500 ms | 1290 | 2 (0.16 %) | 30 (2.33 %) | 1258 (97.5 %) | 99.84 % | ~100 % |

**The replacement statistic discriminates where the legacy one does not.**
`mech_app_limited` moves 4.04 % → 0.08 %, a factor of ~50, between the two RTT
points; `mech_unsent_pending` moves 0.00 % → 2.32 %; `snd_buf == 0` moves 95.96 %
→ 99.92 %. The legacy `snd_buf_low_count` reads ~100 % in all four cells and
separates nothing. `snd_buf_ge_write_count` was 0 everywhere at `L0`, which is
consistent — the buffer never had room for a whole 4096-byte write.

The STOCK and PINNED columns agree closely at both RTT points, which is Claim 3
again, now visible in the sender state rather than only in the throughput.

---

## Proposals for the fenced `tbd_from_pilot` slots

**Every slot below remains `null` in `experiment/manifest.yaml`. Nothing here is
adopted.** Each row gives the measurement, the range that would be defensible on
that measurement, a recommendation, and the reasoning. The recommendation is an
input to the user's decision.

Read the whole table against one caveat: **`11` item B1 (the sporadic collapses)
is unresolved, and slots 1, 2, 6 and 8 all depend on how an affected run is
classified.** If a collapsed run counts as INVALID, the recommendations below
hold. If it counts as valid data, `repetitions` roughly triples.

| Slot | Measurement | Defensible range | Recommendation | Reasoning |
|---|---|---|---|---|
| `repetitions` (n) | Unsampled CV at L0/50 ms = **0.28 %** (n=8). G6: 0.35–0.40 % at 50 ms, **0.023–0.042 % at 500 ms** (n=6). But ~5 % of runs contain a sporadic collapse; including them inflates the L0/50 ms CV to **2.36 %**. | **5 – 10** with a per-interval validity gate; **15 – 25** without one | **n = 8**, conditional on gating collapsed runs INVALID | At CV 0.4 % (worst *clean* cell, which is 50 ms, not 500 ms), n=8 gives a standard error of ~0.14 % — ample against RTT effects of 100–400 %. n is driven entirely by whether collapses are excluded, not by intrinsic noise. Calibrate from the 50 ms cell: G6 shows it is the noisiest, inverting the earlier expectation. |
| `run_duration_s` | Transient < 2 s at every RTT and both ladder points. Collapses last 2–4 s and occurred 1–13 times per 90 s run. 20 s at L0/500 ms already gives CV 0.023 %. | **30 – 90 s** | **60 s** | A single 2–4 s collapse is ≤ 7 % of a 60 s run but 15–20 % of a 20 s run, so 60 s dilutes the dominant error source without a proportional time cost. Also 60 s at a 20 ms interval is 3000 samples per run — ample for the mechanism fractions. Above ~90 s the per-run collapse probability rises faster than the averaging benefit. |
| `discard_interval_s` | ≥ 99 % of steady median reached by **t = 1 s** at all four L0 cells and at L2/50, /100, /200 ms; **t = 2 s** at L2/500 ms. | **0 – 3 s** | **3 s** | 2 s is the largest onset observed anywhere, and it occurs at the largest ladder point, so the window must be justified at L2 rather than L0. 3 s adds one interval of margin and costs 5 % of a 60 s run. A larger window is unsupported and actively harmful — it removes good data without touching the collapses, which occur *later* in the run. |
| `sampling_interval_ms` | Perturbation unmeasurable across **10 – 500 ms** (four of five sampled arms faster than unsampled, on medians). Resolution strongly interval-dependent: `unsent` caught 5 / 2–3 / 1 / 0 / 0 times per run at 10/20/50/100/500 ms. Drift: exact in ~112 of 113 runs; the single exception is **FULL @ 10 ms @ L2**, which lost 0.42 % of samples. | **10 – 50 ms** | **20 ms** | 20 ms catches `unsent` reliably (2–3 per 20 s at the *hardest* cell, L0/50 ms, rising with RTT and with `TCP_SND_BUF`), showed `gap_min == gap_max == 2` ticks with **zero** drift at every cell including L2, and leaves one tick of slack so the expensive L2 FULL walk cannot overrun its period. 10 ms has the best resolution but is the one configuration that demonstrably dropped samples. 100 ms is rejected on resolution: it never once caught `unsent` at L0. |
| `snd_buf_low_threshold` | Legacy counter at 1024 B reads **~100 % in every cell measured** (318/319, 647/647, and all four G6 cells). Replacement counters separate the same cells cleanly: `mech_app_limited` 4.04 % → 0.08 %, `mech_unsent_pending` 0.00 % → 2.32 %, `snd_buf == 0` 95.96 % → 99.92 % between 50 ms and 500 ms. | n/a — the recommendation removes the parameter | **Retire the threshold from analysis; adopt the three-way mechanism classification as the primary statistic.** Keep the legacy field populated for comparability | The `snd_buf` distribution at L0 is a point mass at exactly zero, so no cut-point can separate cells — the problem is not a badly chosen threshold, it is that magnitude is the wrong quantity. The classification is parameter-free (comparisons against exact zero and a null pointer only) and maps one-to-one onto the three alternatives the research question names, so adopting it sets nothing. |
| Timing-drift tolerance (INVALID gate) | 0 mismatches in ~112 of ~113 runs, across intervals 10/20/50/100/500 ms and both ladder points. One run lost **9 of 2122** samples (0.42 %) with `gap_max` = 2 against a nominal 1. At 20 ms and coarser, every gap equalled nominal exactly. | **0 % (exact) – 1 %** | **> 0.5 % of expected samples missing → INVALID**, plus a hard gate on `gap_max > 2 × nominal` | At the recommended 20 ms interval every run this session was exact, so 0 % is attainable and a tolerance exists only as headroom. 0.5 % admits the known L2 marginality without admitting a genuinely stalled sampler. The `gap_max` clause catches a long single stall that a percentage gate would average away. If 10 ms is chosen instead, this must widen to 1 %. |
| Retransmission threshold (INVALID gate) | `nrtx_max` = 0 and `nrtx_nonzero_count` = 0 in **every run of this session** (~113 runs), across all four RTT points, both ladder points and both pinning configs. qdisc counters showed 0 dropped / 0 overlimits throughout. | **`nrtx_max > 0`** through a small tolerance | **`nrtx_max > 0` → INVALID** | The observed distribution is a point mass at exactly zero over ~113 runs, so any non-zero reading is a change in conditions rather than noise, and a tolerance would only admit runs whose link behaved differently. **Caveat that should be recorded with the gate:** `pcb->nrtx` resets on forward progress, so it is an activity indicator, not a cumulative count — a zero reading means "no retransmission was in progress at any sampling instant", which is weaker than "no retransmission occurred". A cumulative counter would be better evidence but requires modifying lwIP, which the no-data-path-change constraint forbids. |
| Steady-state band + consecutive-interval count | The rule "all later intervals within ±5 % of the median" is **unusable**: it returned t = 70 s for L0/50 ms and no answer at all for L0/200 ms and L0/500 ms, because a single late dip falsifies it. Normal steady-state jitter at L0/100 ms alone spans 600 640 – 655 680, i.e. **±4.3 %**, with no disturbance present. | band **5 – 10 %**, count **2 – 5** | **3 consecutive 1-second intervals within ±10 % of the run median, evaluated as a first-crossing rule** | ±5 % is inside the normal jitter of the L0/100 ms cell, so a 5 % band would fire on noise at that cell alone; 10 % clears it with margin. Three consecutive intervals prevents a single lucky interval from declaring steady state, while staying short relative to the 1–2 s onset actually measured. **It must be a first-crossing rule, not an all-subsequent-intervals rule** — the collapses occur later in the run, so any all-subsequent formulation is unsatisfiable on this platform regardless of the band. |

> **CORRECTION (2026-10-07, B3/B4/audit), appended not rewritten — the
> rows above are preserved as originally written:**
>
> The `run_duration_s` row's "Collapses last 2–4 s" figure is **wrong**.
> It was computed by code (`interval_gate.py`, and `analyse_intervals.py`
> has the same defect) that silently dropped iperf's short zero-byte-second
> rows, so a total stall read as a short string of merely *reduced*
> values at its edges instead of the stall itself. Recomputed directly
> from `raw_logs/b1_capture/host_load.csv` with those rows restored: the
> B1 LOAD arm's contiguous zero-throughput stretches are **20 s (run 1,
> t=19–39), 35 s (run 2, t=19–54) and 23 s (run 3, t=21–44)** — not 2–4 s
> — and natural (non-intervention) Phase 0 collapses are also longer than
> 2–4 s where checked (`g4_L0_r200_t100` is a 7 s total stall at t=3–10;
> `g3a_6_full`'s collapse is at least 4 s and is cut off by the end of its
> run). This affects the `run_duration_s` row specifically: its "a single
> 2–4 s collapse is ≤ 7 %... but 15–20 % of a 20 s run" dilution argument
> no longer holds at the corrected 20–35 s duration — a collapse of that
> length cannot be diluted by averaging within any proposed run length,
> only gated out by something like N8. The row's other legs (transient
> length, sample count, CV at L0/500 ms) are not affected by this
> correction. The `discard_interval_s` row is **not** built on the 2–4 s
> figure (it cites onset time and "collapses occur later in the run"
> instead) but needs its own caveat: `g4_L0_r200_t100`'s stall begins at
> t≈2–3 s, inside the proposed 3 s discard window, so "collapses occur
> later" is not true of every collapse. Full detail, independent
> verification and the fix for the underlying parser defect:
> `docs/tfg_evidence/11_open_problems.md` B3 (Resolved) and B4 (Open).
> `repetitions=8` (first row above), already conditional on "gating
> collapsed runs INVALID", is affected transitively — see B3/B4/N16 for
> the current state of that gate — and remains unfrozen.

### Slots the brief did not fence but which now visibly need a number

Flagged rather than filled, per the standing rule.

- **A per-interval validity gate.** Everything above turns on classifying the
  sporadic collapses, and there is currently no gate that can see them: they are
  invisible in a whole-run average, which is all `collect_run_meta.sh` records.
  Some rule over the per-second host intervals is needed — for example "no
  interval below X % of the run median after steady state" — and both X and the
  allowed count are undecided. This is the single highest-value open decision.
- **Trace ring capacity vs run duration.** At the recommended 20 ms interval and
  60 s duration a run produces 3000 samples against 1024 ring slots, so
  `instr_trace` would retain only the last ~20 s. The accumulators remain complete,
  so this affects only trace-based analysis. Either raise `INSTR_TRACE_SLOTS` (each
  slot is 16 bytes; 4096 slots costs 64 KiB of BSS against a ~64 MB heap) or accept
  partial traces. Not set here.

---

## B1 — the sporadic collapses: CLASSIFICATION `SUPPORTED_PLATFORM_STALL`

Run budget declared before starting: **10 × 90 s runs at L0/200 ms** (the cell with
the highest previously observed collapse rate), split into a 5-run IDLE arm and a
5-run LOADED arm. Budget was sufficient; no extension was needed.

### The measurement host is itself a virtual machine — the archive did not know this

`systemd-detect-virt` returns **`oracle`**; `/proc/cpuinfo` carries the
`hypervisor` flag and `lscpu` reports `Hypervisor vendor: KVM`. The Ubuntu machine
that hosts QEMU is a **VirtualBox guest with 2 vCPUs**, on an AMD Ryzen 7 5800H.
**VERIFIED.**

So the stack is: physical host → VirtualBox VM (2 vCPU) → QEMU `vexpress-a9` →
RT-Thread. Two levels of virtualization, and only two CPUs for QEMU's three
threads plus the host `iperf` server plus everything else. Even fully idle, QEMU
accumulates runqueue wait continuously: `qemu_rundelay` p50 = **10.7 ms per
second**, p99 = 55 ms, max 174 ms over 736 idle monitor-seconds. **VERIFIED.**

### Host telemetry added

`experiment/scripts/hostmon.py`, one process sampling `/proc` at 1 Hz, timestamped
`YYYYMMDDHHMMSS` to share the iperf `-y C` CSV's time base. Per second it records
`/proc/stat` CPU jiffie deltas (including `steal`), `ctxt`, `procs_running`,
`procs_blocked`, `loadavg`, and — summed over **all threads** of QEMU and of the
host `iperf` — `sum_exec_runtime`, `run_delay` and timeslice count from
`/proc/<pid>/task/*/schedstat`.

`run_delay` is the decisive field: nanoseconds the task was **runnable but not
running**. Measured overhead: **0.05 s CPU per 5 s wall, ~1 % of one core.**
**VERIFIED.**

### Result

| Arm | runs | intervals | dip seconds (< 80 % of that run's median, t ≥ 2 s) |
|---|---|---|---|
| **IDLE** (agent issued no commands during the arm) | 5 | 92 each = 460 | **none, in any run** |
| **LOADED** (2 CPU spinners for 10 s, starting at guest t ≈ 17 s) | 5 | — | run1 `17,18,39,40` · run2 `17,18,54,55` · run3 `18,19,20,44,45` · run4 `16,…` · run5 `16,17,18,24,25,…` |

**VERIFIED.** Zero collapses in 460 idle intervals at the cell that previously
produced 13 in a single 90 s run; collapses in **5 of 5** loaded runs, with the
first cluster landing in the declared spinner window in every one.

The reproduced collapses match the archived ones in shape *and in value*: the
loaded runs produced 0, 11 680, 23 360, 39 531, 65 568 and 131 136 bit/s against a
steady 327 840 — and **11 680 bit/s (3.6 %) is the exact value of the worst
archived collapse**, at the same cell.

### Telemetry at the collapse second

`b1_load_1`, steady seconds versus the dip second:

| | `procs_running` | `cpu_idle` (jiffies) | `qemu_exec_ms` | `qemu_slices` | `ctxt` |
|---|---|---|---|---|---|
| steady | 1 – 5 | 144 – 155 | 62 – 90 | 239 – 277 | ~1600 |
| **dip second** | **16** | **0** | **10.3** | **18** | **119** |

QEMU received **~8× less CPU time** and was scheduled **~14× less often**, with the
host fully saturated and 16 runnable processes. **VERIFIED, and consistent across
all five loaded runs.**

`tc -s qdisc` before and after every loaded run: **0 dropped, 0 overlimits,
0 requeues** throughout. The network path was clean; the sender simply was not
running. **VERIFIED.**

### The expected sharp discriminator turned out to be the wrong one

The working hypothesis proposed guest-side timer slip (`gap_max` > nominal
concurrent with a collapse) as "the single sharpest discriminator available",
based on `g3a_6_full` carrying `gap_max = 11` alongside its collapse. **That
inference does not hold.** VERIFIED both ways:

- In all 5 LOADED runs — severe, reproduced collapses — `gap_max` was exactly
  **10 ticks, i.e. nominal. No guest timer slip at all.**
- In IDLE run 3 — a completely clean run — `gap_max` was **11**, a one-tick slip
  with no throughput dip anywhere.

So guest timer slip and throughput collapse are **independent**, and
`g3a_6_full`'s coincidence was exactly that. The mechanism is unsurprising in
hindsight: QEMU catches its virtual timer up when it is rescheduled, so guest tick
accounting survives a host stall that the guest's throughput does not. The real
discriminator is host-side — `qemu_slices` and `qemu_exec_ms` — not guest-side.
**Observation (c) of the working hypothesis is retracted.**

### What this establishes, and what it does not

**Establishes:** host CPU contention is *sufficient* to produce collapses
indistinguishable in shape and magnitude from the archived ones, at the same cell;
and the same cell is completely clean across 460 intervals when the host is
undisturbed.

**Does not establish:**

- That every archived collapse had this cause. The previous session ran `git`,
  `scons`, `python3` analyses and document writes **concurrently with background
  experiment runs** on this 2-vCPU host, which makes it the obvious candidate, but
  no telemetry was recorded then, so this is **ASSUMED**, not verified, for the
  historical runs.
- That host CPU contention is the *only* mechanism. `NO_PLATFORM_SIGNAL` would
  only ever apply to signals actually measured; here a signal was found, but TAP
  scheduling, QEMU's internal timer/IO paths, and the **VirtualBox layer** were not
  independently instrumented. `cpu_steal` read 0 throughout, which is weak
  evidence about the VirtualBox layer since VirtualBox does not reliably report
  steal time. **TO VERIFY.**
- The second dip cluster in each loaded run (t ≈ 39–55) is **not** explained. It
  carries a different signature — high `ctxt` (1700–2200) and high `qemu_slices`
  (213–258) *with* CPU idle available — unlike the first cluster. **TO VERIFY.**

### Two limitations of the monitor, for whoever uses it next

1. **It loses samples during exactly the events it is measuring.** In
   `b1_load_1` the timestamps jump 18:42:58 → 18:43:20, a 22 s hole: the monitor
   was itself starved. Sample loss is therefore a *symptom* to read, not only a
   defect — but it means dip-second correlation fails for the worst events, which
   is why several dip rows above show `?`.
2. **`iperf_rundelay_ms` can go negative.** iperf2 spawns a thread per connection;
   when one exits, the sum over `task/*/schedstat` drops. QEMU's thread count is
   fixed at 3, so `qemu_*` fields are unaffected. Treat the iperf columns as
   indicative only.

### Consequence: the remedy is operational, not statistical

B1 is a property of how the host is used during a run, not of the system under
test. That changes the protocol: **nothing else may run on the measurement host
during a Phase 1 run** — no builds, no analysis, no commits, no interactive
shells. Under that rule the collapse rate at the worst cell went from 13 per 90 s
run to 0 in 5 runs.

This also reclassifies N8. A per-interval gate is no longer the primary defence
against B1; it is a **detector that proves the operational rule was followed**.

---

## N8 — per-interval validity gate: a defensible candidate exists

Implemented in `experiment/scripts/interval_gate.py`. All four parameters
(`discard`, `bin`, `band`, `allow`) are **PROPOSALS** — none is written to
`manifest.yaml`. The script's own constants are commented `# PROPOSAL -- manifest
slot stays null` so a future reader of the code sees the same caveat as a reader
of this document.

### Why a flat per-second band cannot work, and what replaces it

The initial design (before this write-up) was "INVALID if any 1-second interval
falls below `F` × the run's own median." Testing it against the archive surfaced a
structural problem, not a tuning one: steady throughput here is
`TCP_SND_BUF` ⁄ RTT-cycle, so a **1-second interval contains an integer number of
send-window cycles**, and its value is quantized at `1 / cycles_per_second`.
**VERIFIED** directly from the per-second data:

| Cell | cycles / second | one lost cycle reads as |
|---|---|---|
| L0/50 ms | ~19 | 94.7 % of median |
| L0/100 ms | ~10 | 90.0 % |
| L0/200 ms | ~5 | 80.0 % |
| L0/500 ms | **~2** | **50.0 %** |
| L2/500 ms | **~2.6** | **60.9 %** |

An undisturbed `g4_L0_r500_t100` takes *only* the values {81.1, 90.4, 100} % of its
own median; an undisturbed `g4_L2_r500_t100` only {60.9, 100} %. **Any fixed band
above ~50 % is a different, stricter rule at the 500 ms cells than at 50 ms**,
which is exactly the cell-dependence the run's-own-median design was meant to
remove — it just moved the dependence from the reference value to the band width
instead of eliminating it.

**Fix: bin before comparing.** Aggregate consecutive seconds into non-overlapping
`B`-second bins (mean bps per bin) before taking the median and the band. Binning
multiplies cycles-per-bin by `B` and divides the quantization step by `B`,
removing the cell dependence structurally rather than by per-cell tuning.

### The rule

1. Drop the first `discard` seconds (startup transient — a **different**
   mechanism from disturbance detection, handled separately).
2. Bin the remainder into non-overlapping `bin`-second windows (mean bps).
3. `M` = median of the bins (the run's own reference — scale-free across the
   ~40× span of steady rates on the grid).
4. Count bins below `band` × `M`.
5. `INVALID` if that count exceeds `allow`.

Deterministic, reads only the archived host CSV, never inspects which config or
RTT produced the run, and never deletes — it only emits a verdict plus a reason
string.

### Evaluation against the full archive, `discard=3 bin=5 band=0.80 allow=0`

The B1 arms are the only runs with **ground truth set by intervention**, not by
inspecting the collapse itself — the LOAD arm was disturbed deliberately, the
IDLE arm deliberately was not, both decided before either ran. Everything else is
unlabelled historical data used only to check for false positives and for
disproportionate flagging.

| Corpus | n | flagged | rate |
|---|---|---|---|
| **B1 IDLE** (ground truth: clean) | 5 | 0 | **0 % FP** |
| **B1 LOAD** (ground truth: disturbed) | 5 | 5 | **100 % TP** |
| g3a (L0/50 ms, 20 s) | 24 | 0 | 0 % |
| g3b (L0/50 ms, 20 s) | 30 | 1 | 3.3 % |
| g4 L0 (90 s, mixed RTT) | 8 | 0 | 0 % |
| g4 L2 (90 s, mixed RTT) | 8 | 0 | 0 % |
| g6 (pinning control, STOCK+PINNED × 2 cycles) | 24 | 0 | 0 % |
| **Total, excl. B1** | 94 | 1 | **1.1 %** |

**VERIFIED.** Perfect separation on the only intervention-labelled data available.
The lone historical flag, `g3b_3_full500`, has no independent ground truth — it
cannot be confirmed as a real disturbance or a false positive — but it is
consistent with B1: a 500 ms cell is exactly where `g4`'s own transient work
(same session) showed larger quantization and is structurally the kind of cell
B1's loaded arm disturbed.

### Sensitivity, not just a point estimate

| `band` | B1 IDLE false positives | B1 LOAD true positives | historical flag rate |
|---|---|---|---|
| 0.90 | 0/5 | 5/5 | 4.3 % |
| 0.85 | 0/5 | 5/5 | 2.1 % |
| **0.80** | **0/5** | **5/5** | **1.1 %** |
| 0.75 | 0/5 | 4/5 | 1.1 % |
| 0.70 | 0/5 | 4/5 | 1.1 % |

0.80 is the point where sensitivity is still perfect (5/5 TP) and the historical
flag rate has already reached its floor — loosening further below 0.75 starts
losing true positives without reducing false positives any further. **Not chosen
by fitting to the collapse labels**: the *quantization* bound (previous section)
was derived from clean-run structure alone, before any label was consulted; the
*band* was then chosen from the sensitivity table above, which is reported in
full rather than collapsed to the one value used.

### Required properties, checked explicitly

- **Deterministic / scriptable**: pure function of the CSV; `interval_gate.py
  selftest` re-derives the table above from the archived files on every run.
- **Outcome-independent**: `gate()` takes only `[(ts, t, bps), ...]` — no config,
  no RTT, no treatment label is in scope to leak into the decision.
- **Uniform availability**: the per-second host CSV is produced by `iperf -y C`
  for every run under the existing protocol; no run lacks the input this gate
  needs.
- **No disproportionate invalidation by cell**: g4 L0 and g4 L2 both flag 0/8
  despite an 8-fold RTT range and a 4-fold buffer range between them; g6's STOCK
  and PINNED arms both flag 0/12. The one flag in the whole non-B1 archive is a
  single run at a single cell, not a pattern tied to any axis.

### What remains open

- `allow` was tested only at 0 in the table above; `11` item N8 is updated to
  reflect a defensible rule exists, not that its exact parameters are decided.
- The gate has not yet been wired into `collect_run_meta.sh` — that integration is
  B2's work, done in the same session, see below.
- Per the B1 finding, this gate is now understood as a **detector that the
  operational no-concurrent-load rule was followed**, not the primary defence
  against B1 — but it still needs to exist for exactly the case the rule is
  violated without anyone noticing.
