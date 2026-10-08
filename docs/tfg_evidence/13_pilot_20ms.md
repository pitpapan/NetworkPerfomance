# 13 — Supplementary pilot: 20 ms sampling interval, L1/L2 coverage

**Status at creation: PLAN ONLY, before any measurement.** This is a
task-specific pilot plan, not a previously frozen protocol and not a
sample size established by earlier evidence. It exists to close the gap
`11_open_problems.md` N18 identified: zero mechanism-fraction (`mech_*`)
evidence anywhere at L1, L2, RTT=100 ms, or `sampling_interval_ms=20`.

None of these values are written into `experiment/manifest.yaml`'s
`tbd_from_pilot` block. This file, and the pilot archive under
`raw_logs/pilot_20ms/`, are the complete record — separate from the
formal 19-cell matrix and from `experiment/results.csv`.

## Purpose

Obtain repeated joint sender-state evidence at the proposed 20 ms
sampling interval, including the two previously-unmeasured buffer levels
(L1, L2), under a common 60 s requested observation period, and assess
the resulting variability. This does **not** decide the formal
`repetitions` count, authorize Phase 1, or freeze any protocol parameter.

## Fixed schedule: 24 attempts maximum

| Config | `TCP_SND_BUF` | RTT | Scheduled attempts |
|---|---|---|---|
| L0 | 8196 | 50 ms | 6 |
| L1 | 16384 | 50 ms | 6 |
| L2 | 32768 | 50 ms | 6 |
| L2 | 32768 | 500 ms | 6 |

`TCP_SND_QUEUELEN = MEMP_NUM_TCP_SEG = 44` (pinned controls) at every
config, exactly as the formal matrix defines L0/L1/L2 — built via
`experiment/scripts/set_config.sh <L0|L1|L2>`, same as every prior formal
build. No RTT=100/200 ms, no platform/pinning-control cells, no
alternative sampling interval or duration. Not an allocation that may be
expanded mid-task.

**Allocation rationale** (recorded, not re-derived mid-task): L0/50 ms is
a reference under the new sampling/window settings against the existing
`analyse_mechfrac_variance.py` L0/50 ms (n=6, 100 ms-interval) result.
L1/50 ms and L2/50 ms fill the ladder gap at the one RTT already known to
be throughput-noisiest (R11). L2/500 ms samples the large-buffer,
long-RTT corner, where `mech_unsent_pending` is expected to be largest
(per `07`/`08`'s `unsent` sweep). The historical L0/50 ms variability does
**not** establish that 50 ms is worst at every buffer level — L2/500 ms
exists specifically to give one data point against that assumption.

## Run order, blocking, and randomization

`block_by: build` (L0, then L1, then L2 — one `scons` build per block,
matching `manifest.yaml`'s existing `run_ordering` convention).
`randomize_within_block: rtt` — L0 and L1 blocks have only one RTT each,
so no randomization is possible within them. The L2 block has two RTTs
(50/500 ms); its 12 attempts are interleaved in a **fixed, pre-recorded**
random order, generated now, before any measurement, and not to be
reordered after seeing outcomes:

```
seed = 20261007  (python3 random.seed(20261007); random.shuffle(['50']*6+['500']*6))
L2 execution order: 500,500,500,50,500,500,50,500,50,50,50,50
```

### Planned run IDs, in execution order

| # | run_id | config | RTT |
|---|---|---|---|
| 1 | `pilot20_L0_r50_1` | L0 | 50 |
| 2 | `pilot20_L0_r50_2` | L0 | 50 |
| 3 | `pilot20_L0_r50_3` | L0 | 50 |
| 4 | `pilot20_L0_r50_4` | L0 | 50 |
| 5 | `pilot20_L0_r50_5` | L0 | 50 |
| 6 | `pilot20_L0_r50_6` | L0 | 50 |
| 7 | `pilot20_L1_r50_1` | L1 | 50 |
| 8 | `pilot20_L1_r50_2` | L1 | 50 |
| 9 | `pilot20_L1_r50_3` | L1 | 50 |
| 10 | `pilot20_L1_r50_4` | L1 | 50 |
| 11 | `pilot20_L1_r50_5` | L1 | 50 |
| 12 | `pilot20_L1_r50_6` | L1 | 50 |
| 13 | `pilot20_L2_r500_1` | L2 | 500 |
| 14 | `pilot20_L2_r500_2` | L2 | 500 |
| 15 | `pilot20_L2_r500_3` | L2 | 500 |
| 16 | `pilot20_L2_r50_1` | L2 | 50 |
| 17 | `pilot20_L2_r500_4` | L2 | 500 |
| 18 | `pilot20_L2_r500_5` | L2 | 500 |
| 19 | `pilot20_L2_r50_2` | L2 | 50 |
| 20 | `pilot20_L2_r500_6` | L2 | 500 |
| 21 | `pilot20_L2_r50_3` | L2 | 50 |
| 22 | `pilot20_L2_r50_4` | L2 | 50 |
| 23 | `pilot20_L2_r50_5` | L2 | 50 |
| 24 | `pilot20_L2_r50_6` | L2 | 50 |

Attempt 1 (`pilot20_L0_r50_1`) doubles as the end-to-end collection check
under the reconstructed measurement harness (see Preflight). It counts
within the 24-attempt budget; if it satisfies the requirements below it
is retained as the first usable pilot repetition, not discarded or
redone as a separate "test" run.

## Pilot-only settings

- Requested run duration: **60 s total, including startup** (not 60 s
  post-discard).
- Initial discard candidate: **3 s** (candidate only — see Section 4
  below for how it is applied to the numerator/denominator, not just
  subtracted from one).
- Sampling interval: **20 ms** (`msh instr_interval 20`).
- Instrumentation mode: **tier=full** (`msh instr_tier full`) — the only
  mode that populates `mech_*`.
- Sender direction, delay topology, pinned queue/segment controls: same
  as every formal build (unchanged).
- No artificial link-rate cap (unchanged).
- Netem delay applied via `sudo -n /usr/local/sbin/tfg-set-netem <ms>`
  **only** — never plain `sudo tc`/`set_netem.sh`, which require an
  interactive password on this host (memory: `tfg-netem-sudo-wrapper`) and
  will stall a non-interactive session.

## Preflight required before attempt 1 (recorded here, verified by the delegate before measuring)

- Intended vs. effective build/runtime configuration: `set_config.sh`'s
  own macro-dump verification (reused, not reimplemented).
- `packages/netutils-latest/iperf/iperf.c`'s hand-applied hooks are
  present and match the expected hook set (N5 — still no tracked
  reconstruction artifact as of this plan; verify presence, do not
  silently proceed if absent, and do not newly install/redesign it as
  part of this pilot).
- Actual sampler interval and tier as read back from the running guest
  (`msh instr_interval`/`instr_tier` with no argument, if that reads
  current value — confirm the command's own read-back behavior, don't
  assume), not merely the command that was sent.
- Trace capacity (`INSTR_TRACE_SLOTS`, confirmed this session to be 8192
  in the current source) against 60 s at 20 ms ≈ 3000 samples — confirm
  headroom, and confirm the trace's own overflow/wrap indicator if one
  exists.
- Current joint-state field definitions (`mech_app_limited` /
  `mech_unsent_pending` / `mech_ack_pending`, already exhaustive/exclusive
  per this session's verification) — reuse, do not re-derive.
- Per-run counter reset and connection lifecycle: `instr_reset <run_id>`
  before each attempt; confirm the dump's own `run_id` field matches what
  was requested (the existing run_id-mismatch gate), and that
  `tcp_active_pcbs` membership + port-pair validation (A2, still
  unexercised by a deliberate race, per `11`) behaves as documented.
- Host-side measurement control: the previous session's `tmux`/`msh`
  control harness (`experiment/scripts/b1_capture_run.sh`,
  `07_reproduction_notes.md`) depended on a scratchpad `lib.sh` and a
  named tmux session from an **earlier, now-gone Claude session** —
  confirmed gone (`tmux ls` → no server, no matching process) at plan
  time, 2026-10-07. The delegate must re-establish this control
  mechanism (a fresh detached `tmux` session, `send-keys`/`capture-pane`)
  before attempt 1, following `07_reproduction_notes.md`'s documented
  command pattern, and must treat its own first successful boot +
  msh-prompt reach as part of preflight, not as attempt 1 itself.
- Unique host CSV / `instr_dump` / trace association per attempt: do
  **not** accept the collector's positional connection-index convention
  as proof of identity by itself (N13) — cross-check using the iperf
  server's own per-connection source port, the attempt's own timestamp
  window, and the `instr_dump`'s own `run_id` field together.
- Live qdisc evidence: `tc -s qdisc show dev tap0` captured pre- and
  post-attempt, every attempt (same convention as `b1_capture_run.sh`).

## Measurement windows and clock discipline

- Document, with the actual observed numbers (not assumed), how a "60 s
  requested" run maps to: the guest-side `instr_dump` accumulator window
  (whole-run, from `instr_reset` to `instr_dump`), the host-side iperf
  interval series (its own `-y C` per-second timestamps), and the trace
  ring's own window if it wraps before 60 s elapses at 20 ms (it should
  not, per the trace-capacity check above, but confirm).
- The primary pilot state fractions must exclude the first 3 s using an
  auditable method the current instrumentation actually supports — if
  only whole-run accumulators exist (no post-hoc numerator/denominator
  split), use the timestamped per-sample trace (`instr_trace`) to compute
  a discard-excluded fraction, and preserve the original whole-run
  accumulators alongside it for cross-checking, never silently replacing
  one with the other.
- Record the clock domain and start reference separately for: host
  throughput intervals (iperf's own per-second timestamps), guest samples
  (`instr_dump`'s tick-based fields), and any host telemetry captured.
  Do not assume host and guest clocks advance identically during any
  anomaly — this session's B4 work already demonstrated they do not
  during a severe stall, and nothing here manufactures alignment inside
  an unobserved interval.
- A complete guest-sampled state record may still have limited power to
  explain host-wall-time throughput; report that limitation explicitly
  rather than implying the two always correspond.
- No new guest-span/host-duration validity detector is created here (an
  unadopted proposal from the B4/N8 work — stays unadopted).

## Execution discipline

- One independent TCP connection per attempt, `instr_reset` before each.
- During an active measurement: only the experiment components and
  logging already specified run concurrently (QEMU, the iperf
  client/server pair, `hostmon.py`, the qdisc pre/post capture) — no
  builds, Git operations, analysis jobs, stress spinners, or unrelated
  diagnostics while a 60 s window is open (CLAUDE.md's existing
  measurement-resource rule; B1/R13 is exactly why).
- A finite operational timeout, recorded with its clock basis, bounds
  each attempt. A timeout produces an incomplete/censored attempt — not
  evidence of a particular platform cause by itself.
- Every started attempt is preserved, including explicit zero throughput
  and anomalous-but-compliant observations. No automatic replacement
  attempts. No early stopping because intervals already look narrow. No
  extra repetitions to manufacture six clean runs per stratum. If a
  defect threatens the trustworthiness of *subsequent* collection
  (configuration, identity, instrumentation, or data-integrity), stop the
  affected remaining attempts and report the specific blocker rather than
  continuing on an unchanged, now-suspect setup.

## N8 kept separate from pilot classification

Run the existing N8 detector (`interval_gate.py`, proposal parameters
`discard=3 bin=5 band=0.80 allow=0`, unchanged, not tuned here) and
preserve its raw verdict unchanged. The shared collector
(`collect_run_meta.sh`) may still fold any `INVALID`/`INSUFFICIENT`
verdict into its legacy `valid` boolean — that boolean is **not** treated
as the scientific inclusion decision for this pilot. A separate, traceable
pilot-analysis record (output of the extraction wrapper below) carries,
per attempt: measurement completeness, any demonstrated protocol/
instrumentation failure (with its specific gate and reason), the N8
verdict and reason as its own field, any other observed anomaly, and
metric-by-metric eligibility with a stated justification. An
otherwise-compliant anomalous run is retained in the primary pilot
summaries, not excluded for an N8 flag alone; N8 `INSUFFICIENT` alone is
not treated as proof that required data are missing (check the specific
reason). Explicit zero-throughput records, missing records, and
ambiguous connection associations are kept distinct from each other.

No change to `collect_run_meta.sh`'s validity semantics, the formal
`valid` boolean, or `manifest.yaml`'s schema is authorized by this
pilot. Any extraction/analysis code needed is a pilot-only wrapper,
reproducible, preserving every source artifact.

## Analysis plan (after measurement, not before)

Per usable attempt: run identity/config, actual analysis window and clock
domain, accepted sample count, numerator/denominator for each `mech_*`
fraction, trace coverage/overflow status, throughput over the
corresponding host interval, anomaly/completeness notes.

Per stratum (L0/50, L1/50, L2/50, L2/500 — each kept separate; **not**
pooled with each other, and **not** pooled with the existing 100 ms-interval
L0 evidence from `12`'s "Repetitions planning objective" section, which is
shown only as a separate historical comparison): scheduled/attempted/
complete/analysis-eligible counts, per-run fractions, per-state mean,
between-run SD in percentage points, observed range, and
`h = t_(0.975, m-1) * s / sqrt(m)` where `m` is the number of
analysis-eligible independent runs in that stratum — using the same 2 pp
objective `12` already recorded, not a new one. An all-zero observation
is reported as **OBSERVED ZERO**, not asserted structural, unless an
independent structural argument is given (e.g. the 50 ms RTT argument
already used for `mech_unsent_pending` in `12`, which may or may not
transfer to L1/L2 — check, don't assume). A zero-width interval from a
degenerate/discrete fraction is reported as a limitation, not as
precision achieved.

Predeclared within-run window sensitivity, where trace timestamps support
it, using the run-relative clock convention established above: `[3,30)`,
`[30,60)`, `[3,60)`. These are derived windows from the same attempt, not
extra independent runs, and are not counted toward `m`. `[3,60)` is the
predeclared primary window; it is not swapped for whichever window shows
lower variance after the fact.

## Stopping conditions

- Normal completion: all 24 attempts executed (regardless of how many
  turn out analysis-eligible).
- Early stop: a configuration/identity/instrumentation/data-integrity
  defect is found that would compromise *subsequent* attempts under the
  unchanged setup. Report the specific attempt, the specific defect, and
  the exact point the schedule stopped. Already-completed attempts are
  not discarded.
- No scenario authorizes exceeding 24 attempts or silently substituting a
  different stratum's data for a missing one.

## Results: L0/50 ms block (attempts 1–6, complete)

Executed 2026-10-07, after resolving `11` B5 (`tap0` missing — the user
ran the one-time interactive setup; recorded there, not repeated here).
Raw artifacts: `raw_logs/pilot_20ms/pilot20_L0_r50_{1..6}.*`.

**Deviation on attempt 1, disclosed not absorbed**: the control-loop's
stop timing overran the planned 60 s to 87.89 s (a tooling defect in the
delegate's wait procedure, not a platform stall — `hostmon` load stayed
low throughout, N8 found the entire interval series flat with zero
depressed bins). The coordinator independently computed the per-window
`mech_app_limited` fraction from the raw trace before deciding whether to
keep the attempt: `[3,30)=3.19%`, `[30,60)=3.27%`, `[3,60)=3.23%`,
`[60,88)=2.94%` — all within noise of each other, confirming the overrun
window is the same steady-state mixture, not a regime change. Attempt 1
is **retained**, using its `[3,60)` value as the stratum data point.
Fixed for attempts 2–6: the delegate's stop procedure now polls the host
iperf CSV's own elapsed-time column directly (guest spans 60.17–60.36 s
thereafter, no recurrence). A separate, independently-caught
terminal-wrapping display bug in one capture command (attempt 2) was
fixed without re-measuring — the underlying `instr_dump` data was intact,
only the delegate's own line-reassembly needed a fix.

**All 6 attempts' `mech_*` counts sum exactly to `sample_count`** (coordinator
re-verified directly from each `.json`, not taken from either report).
Per attempt, `[3,60)`-windowed (first 3 s of each run's own trace
excluded by timestamp, not by truncating the denominator while leaving
the numerator intact — the method the plan requires):

| run_id | n (post-discard) | `app_limited` % | `unsent_pending` % | `ack_pending` % |
|---|---|---|---|---|
| `pilot20_L0_r50_1` | 2850 | 3.228 | 0.000 | 96.772 |
| `pilot20_L0_r50_2` | 2850 | 3.333 | 0.000 | 96.667 |
| `pilot20_L0_r50_3` | 2850 | 3.754 | 0.000 | 96.246 |
| `pilot20_L0_r50_4` | 2850 | 2.982 | 0.000 | 97.018 |
| `pilot20_L0_r50_5` | 2850 | 3.158 | 0.000 | 96.842 |
| `pilot20_L0_r50_6` | 2850 | 3.404 | 0.000 | 96.596 |

**Stratum summary, n=6**: `mech_app_limited` mean=3.310 %, between-run
SD=0.262 pp, range 2.982–3.754 %. `mech_unsent_pending`=0.000 % in every
run (structural zero at 50 ms, consistent with the existing 100 ms-interval
evidence). N8: `VALID` on every attempt, zero depressed bins.

**Historical comparison, not pooled**: the existing L0/50 ms,
100 ms-interval evidence (`12`'s "Repetitions planning objective"
section, G6 PINNED, n=6) gave mean=4.043 %, SD=1.779 pp — roughly **7×**
larger between-run SD than this 20 ms-interval result. This is reported
as an observation, with an explicit caution against over-reading it: each
20 ms-interval run has ~13× more samples (2850 vs. ~219) than each
100 ms-interval run, so some or all of the smaller between-run SD is
expected from reduced *within-run estimation noise* propagating into the
run-level point estimate, independent of whether the *underlying physical
process* is actually any less variable at a faster sampling interval.
Distinguishing those two explanations is not attempted here.

Applying the same planning calculation as `12` (`h(n) = t_(0.975,n-1) *
s/sqrt(n)`, target ≤2 pp) to this stratum's own `s=0.262` pp: `h(3)`
(t=4.303) `= 0.651 ≤ 2` already; `h(2)` (t=12.706) `= 2.355 > 2`. Smallest
`n` meeting the objective at this one stratum: **3** — markedly smaller
than the `n=6` candidate derived from the 100 ms-interval data. This is
one stratum only; it is not generalized to L1/L2/500 ms here, and it does
not change the `repetitions` candidate recorded in `12` (which stays
unfrozen, pending the remaining strata below and a decision on the
within-run-noise question above).

## Results: L1/50 ms block (attempts 7–12, complete)

Build: `set_config.sh L1` — PASS, effective macros confirmed, `iperf`
linked once, no `rtconfig.h`/`.config` drift. Boot banner on the fresh
QEMU boot confirmed `TCP_SND_BUF=16384` (not 8196) before any attempt —
the same cross-check `collect_run_meta.sh` uses elsewhere, done by eye
here. `tap0` netem confirmed still `delay 50ms` throughout (reboot does
not touch host networking state, verified rather than assumed).

**Anomaly, non-blocking**: the L0 block's `pilot20` tmux/QEMU session
was found already gone (tmux server itself had exited) when the delegate
went to tear it down for the L1 rebuild — no `dmesg` access to confirm a
cause (permission denied), `journalctl`/`free`/`uptime` showed nothing
abnormal. Not a data-loss event (all L0 artifacts were already extracted
and committed in `d780e4f` before this happened), and tearing down that
exact session was this task's own next step regardless. Noted for
awareness if it recurs; not investigated further.

**All 6 attempts' `mech_*` sums re-verified exactly against
`sample_count`** (coordinator, direct from each `.json`). The whole-run
accumulator showed a constant `mech_unsent_pending=5` in every single
attempt, which the coordinator checked by trace position rather than
accepting at face value: in all 6 runs, every `unsent>0` sample falls
in the first 5 trace rows (t=0.00–0.08 s from connection start) — a
connection-establishment burst, not a steady-state phenomenon, and
entirely inside the 3 s discard window. `[3,60)`-windowed, from each
trace:

| run_id | n (post-discard) | `app_limited` % | `unsent_pending` % | `ack_pending` % |
|---|---|---|---|---|
| `pilot20_L1_r50_1` | 2850 | 1.544 | 0.000 | 98.456 |
| `pilot20_L1_r50_2` | 2850 | 1.053 | 0.000 | 98.947 |
| `pilot20_L1_r50_3` | 2815 | 0.746 | 0.000 | 99.254 |
| `pilot20_L1_r50_4` | 2839 | 1.268 | 0.000 | 98.732 |
| `pilot20_L1_r50_5` | 2849 | 1.229 | 0.000 | 98.771 |
| `pilot20_L1_r50_6` | 2850 | 0.982 | 0.000 | 99.018 |

**Stratum summary, n=6**: `mech_app_limited` mean=1.137 %, between-run
SD=0.274 pp, range 0.746–1.544 %. `mech_unsent_pending`=0.000 % in every
run once discard is applied (confirmed, not assumed, per the trace-position
check above). N8 `VALID` on all 6, `stale_count=0`, `trace_written==sample_count`
on every attempt, `gap_max_ticks` 2–4 (two attempts briefly at 3–4, not a
defect). Connection identity: strictly sequential, non-repeating host
ports across the 6 attempts, each with its own `run_id` match.

**Comparison with L0/50 ms** (same interval, same RTT, larger buffer):
`app_limited` mean dropped from 3.310 % (L0) to 1.137 % (L1) — directionally
consistent with a larger send buffer being less often the binding
constraint. Between-run SD is similar in magnitude (0.262 pp vs. 0.274 pp)
— the earlier caution about within-run sample count driving apparent SD
(this session, both strata have ~2850 post-discard samples) applies
equally to both, so this near-equal SD is also consistent with that
explanation, not yet distinguished from a real "variability doesn't
change much with buffer size" claim.

## Results: L2 block (attempts 13–24, complete — pilot finished, 24/24)

Build: `set_config.sh L2` — PASS, `TCP_SND_BUF=32768` confirmed effective
and on the fresh boot banner before any attempt. Netem verified
immediately before **every** attempt (not just on a change), per the
plan: every `r500_*` run's own `.qdisc_pre` shows exactly `delay 500ms`,
every `r50_*` run's shows exactly `delay 50ms` — no stale-delay
mismatch anywhere across the interleaved sequence. Executed in the exact
pre-recorded order (500,500,500,50,500,500,50,500,50,50,50,50); not
reordered. Connection identity: strictly sequential, non-repeating host
ports across all 12 (49153→49164), each cross-checked against its own
qdisc delay and `run_id`.

All 12 `mech_*` triples re-verified (coordinator, direct from JSON) to
sum exactly to `sample_count`. `[3,60)`-windowed, independently
recomputed by the coordinator from every trace (not taken from the
delegate's numbers):

| run_id | n | `app_limited` % | `unsent_pending` % | `ack_pending` % |
|---|---|---|---|---|
| `pilot20_L2_r500_1` | 2850 | 0.386 | 0.000 | 99.614 |
| `pilot20_L2_r500_2` | 2850 | 0.316 | 0.000 | 99.684 |
| `pilot20_L2_r500_3` | 2850 | 0.421 | 0.000 | 99.579 |
| `pilot20_L2_r500_4` | 2850 | 0.175 | 0.000 | 99.825 |
| `pilot20_L2_r500_5` | 2850 | 0.281 | 0.000 | 99.719 |
| `pilot20_L2_r500_6` | 2850 | 0.316 | 0.000 | 99.684 |
| `pilot20_L2_r50_1` | 2849 | 3.756 | 0.000 | 96.244 |
| `pilot20_L2_r50_2` | 2850 | 3.860 | 0.000 | 96.140 |
| `pilot20_L2_r50_3` | 2850 | 3.474 | 0.000 | 96.526 |
| `pilot20_L2_r50_4` | 2850 | 4.526 | 0.000 | 95.474 |
| `pilot20_L2_r50_5` | 2850 | 3.825 | 0.000 | 96.175 |
| `pilot20_L2_r50_6` | 2850 | 4.491 | 0.000 | 95.509 |

**Stratum summaries, n=6 each**: L2/500 ms `app_limited` mean=0.316 %,
SD=0.086 pp, range 0.175–0.421 %. L2/50 ms `app_limited` mean=3.989 %,
SD=0.425 pp, range 3.474–4.526 %. `unsent_pending`=0.000 % in every one
of the 12 runs. N8 `VALID` on all 12; `stale_count=0`,
`trace_written==sample_count` throughout.

**Notable null result, flagged not absorbed**: the plan's own stated
expectation was that L2/500 ms would show the *largest*
`mech_unsent_pending` (per `07`/`08`'s older `unsent` sweep, at a 10 ms
interval and shorter runs). Checked by trace position before accepting
the whole-run accumulator's apparently-confirming numbers (2.47–2.50 %
at every `r500_*` run): in every one of the 12 L2 attempts, 100 % of
`unsent>0` samples fall in a short connection-start burst — `t∈[0,1.5]s`
for the 500 ms-RTT runs (the slow-start ramp, visibly slowed by the
500 ms RTT), `t∈[0,0.14]s` for the 50 ms-RTT runs — and zero such samples
occur at or after `t=3s` in any of the 12. Once `[3,60)` is applied,
`mech_unsent_pending=0.000%` everywhere, at every stratum this entire
pilot measured (L0/50, L1/50, L2/50, L2/500) — a uniform null result,
not a near-miss. This is not necessarily a contradiction of the older
`unsent_nonempty_count` finding (R6, `11` Resolved): that metric counts
any sample with `unsent>0` regardless of `snd_buf`, while
`mech_unsent_pending` requires `snd_buf<=0` (buffer full) *and*
`unsent>0` — a strictly narrower condition that a brief, buffer-not-full
excursion would never satisfy. The two metrics are not nested in a way
that makes one checkable against the other without re-deriving
`unsent_nonempty_count` from this pilot's own traces, which was not done
here. Recorded as an open discrepancy for whoever next reconciles the
G3c sweep's framing with this pilot's, not resolved.

**Within-run window-sensitivity spot-check** (predeclared `[3,30)`/
`[30,60)`/`[3,60)`, not independent runs): `pilot20_L2_r50_4` —
4.593/4.467/4.526 % — stable. `pilot20_L2_r500_4` — 0.370/0.000/0.175 % —
*not* stable in absolute terms, but this is a ~5-sample count over 1500
post-split observations; at this base rate a 0-vs-nonzero half-run split
is ordinary count noise on a rare event, not evidence of a within-run
regime change. Flagged as a specific limitation of the L2/500 ms
stratum's precision (already visible in its own small `n` and discrete
counts), not generalized to the other three strata, which did not show
this.

## Full-pilot summary (24/24 attempts, all four strata)

| Stratum | n | `app_limited` mean % | SD (pp) | range % |
|---|---|---|---|---|
| L0, RTT=50 ms | 6 | 3.310 | 0.262 | 2.982–3.754 |
| L1, RTT=50 ms | 6 | 1.137 | 0.274 | 0.746–1.544 |
| L2, RTT=50 ms | 6 | 3.989 | 0.425 | 3.474–4.526 |
| L2, RTT=500 ms | 6 | 0.316 | 0.086 | 0.175–0.421 |

`mech_unsent_pending = 0.000 %` at every stratum, post-discard (see null
result above). N8 `VALID` on all 24 attempts — zero collapses, zero
host-contention signatures (every `hostmon` capture stayed at normal
load throughout every window).

**Repetitions candidate at the actual Phase-1-candidate settings**
(20 ms interval, 60 s duration — not extrapolated from the earlier
100 ms-interval data): `h(n) = t_(0.975,n-1)*s/sqrt(n)`, target ≤2 pp:

| Stratum | s (pp) | Smallest n meeting 2 pp |
|---|---|---|
| L0/50 ms | 0.262 | 3 (h(3)=0.651) — but see L0's own table above: pilot used n=6 |
| L1/50 ms | 0.274 | 3 (h(3)=0.682) |
| L2/50 ms | 0.425 | 3 (h(3)=1.058) |
| L2/500 ms | 0.086 | 2 (h(2)=0.773) |

Largest across the four tested strata: **n=3** for `mech_app_limited`
precision at these specific settings — smaller than the n=6 figure
derived from the 100 ms-interval archive. Both analyses independently
identify a sampling-related explanation (more samples per run at 20 ms
reduces within-run estimation noise, which propagates into a smaller
apparent between-run SD) as a plausible driver of the difference, which
this pilot does not and cannot resolve on its own (it would need a
repeated-measurement design that varies interval while holding the
run's true physical conditions fixed, which this pilot's design does
not provide). **Not treated as a replacement candidate for `12`'s n=6**:
reported alongside it, consistent with the task's "largest of the
candidates actually represented" instruction applied *within* this
pilot's four strata, not as a license to lower the cross-document
figure. `mech_unsent_pending` still cannot be used for a repetitions
calculation anywhere (uniform structural zero, all four strata).

## What this pilot does and does not establish

- **Covers**: L0/L1/L2 at RTT=50 ms, and L2 at RTT=500 ms, all at the
  actual candidate `sampling_interval_ms=20`/`run_duration_s=60`
  settings — real evidence at the real settings, not extrapolation, for
  these four (config, RTT) cells only.
- **Does not cover**: RTT=100/200 ms at any buffer level (plan explicitly
  excluded them — not an oversight); L0/L1 at RTT=500 ms; L2 at
  RTT=100/200 ms. The repetitions candidate above is bounded by the
  four strata actually measured, exactly as `11` N18 and `12`'s
  "Repetitions planning objective" section already cautioned it would
  be before this pilot ran.
- Does not change, freeze, or supersede `discard_interval_s=3` or
  `sampling_interval_ms=20`'s existing SUPPORTED WITH QUALIFICATION
  status in `12` — this pilot's own data is additional evidence *for*
  `sampling_interval_ms=20` specifically (it worked, cleanly, at three
  buffer levels and two RTTs) but a formal re-assessment of that
  candidate's status is left to the coordinator's write-up in `12`, not
  decided here.
- Does not freeze `repetitions`. `12`'s candidate (n=6) and this
  pilot's own internal candidate (n=3) are both reported; neither is
  adopted as the formal count.

## Audit corrections (evidence-auditor, 2026-10-07; coordinator-reverified)

The bounded post-pilot audit (PASS WITH QUALIFICATION) found the raw
measurements, identity/configuration checks, and `[3,60)` windowing
arithmetic above all correct (independently re-derived by hand from the
traces and matched exactly), but found three interpretive claims above
to be wrong. All three were independently re-verified by the coordinator
directly against the raw files before being accepted — not taken on the
audit's word alone. The sections above are **preserved as originally
written**; corrections are appended here, per project convention, and
formally recorded as superseded claims #11–12 in
`05_invalid_superseded_claims.md`.

1. **The `mech_unsent_pending` "narrower metric" explanation is withdrawn
   (`05` #11).** Checked directly: `unsent_nonempty_count` exactly equals
   `mech_unsent_pending` in every attempt checked (`pilot20_L2_r500_1`:
   76=76; `pilot20_L2_r500_4`: 75=75) — every `unsent>0` sample in this
   archive also had `snd_buf<=0`, so the proposed gap between the two
   metrics never actually occurs here. The real reconciliation with
   `07`/`08`'s older finding: both datasets are measuring the **same
   connection-start burst**, just differently. The older work used
   whole-run counts with no discard; this pilot's `[3,60)` window removes
   exactly that burst. Converting the older counts to elapsed time gives
   ~1.5 s at L2/500 ms and ~0.15 s at L0/L2/50 ms — matching this pilot's
   own burst durations almost exactly, and consistent with a
   once-per-connection event (constant in elapsed time regardless of run
   length), not a periodically-recurring one as `12`'s existing text
   implies in one place. **`12`'s "RTT too short to ever accumulate"
   framing for `unsent_pending` at 50 ms is also imprecise**: `unsent`
   does accumulate briefly during the first RTT at every tested RTT
   including 50 ms; a coarser (10/100 ms) interval was simply too slow to
   usually catch a ~0.15 s burst, which 20 ms-sampling plus a 3 s discard
   now resolves and then discards, respectively.
2. **"N8 VALID on all 24 — zero collapses, zero host-contention
   signatures" is withdrawn (`05` #12).** Two attempts have real,
   confirmed anomalies: `pilot20_L1_r50_3` dips to 32 % of steady
   throughput for 1 s (host interval 8–9 s = 99764 B vs. ~300 KB
   surrounding), coincident with its own `.hostmon.csv` showing
   `qemu_exec_ms` collapsing to 80.3 from a steady ~236 and
   `qemu_slices` to 147 from ~450 at that exact second —
   a real host-scheduling event, not throughput noise.
   `pilot20_L1_r50_4` shows a milder dip (73–76 % of steady, t=3–5 s)
   with ~5 lost guest samples (`sample_count=2989` vs. 2994 expected,
   `gap_max_ticks=4`, twice nominal). N8 passed both only because its
   5-second bins dilute a 1-second dip below the 0.80 band — correctly
   behaving as a detector with known limits (N16), not evidence these
   events didn't happen. **Both runs are correctly retained** (anomalous
   but otherwise protocol-compliant, per this plan's own N8-separation
   policy — this is not a reason to exclude or re-run them) and their
   `[3,60)` fractions remain part of the L1/50 ms stratum as reported;
   only the blanket "zero collapses" narrative is withdrawn. Relabel
   both as anomalous-but-compliant wherever cited, not as clean.
3. **"Structural zero" (used for `mech_unsent_pending`'s result) is
   corrected to "OBSERVED ZERO (post-discard)".** The plan's own Section
   7 reserves "structural" for a result backed by an independent
   structural argument, which was not given here — the whole-run
   `mech_unsent_pending` is non-zero at every stratum (it is only the
   `[3,60)`-windowed value that is zero), so this is an observed
   post-discard zero, not an argued structural one.
4. **"Directionally consistent with a larger buffer binding less often"
   (the L0→L1 `app_limited` comparison) is withdrawn.** `snd_buf>0` is
   classified as `app_limited` precisely because the buffer has room
   (is NOT full); a lower `app_limited` fraction means the buffer was
   full (not app-limited) *more* of the time, the opposite direction
   from what was claimed. The cross-ladder trend is also not monotone
   once L2/50 ms is included (L0=3.310 %, L1=1.137 %, L2/50=3.989 %) —
   no buffer-size trend is asserted.
5. **Repetitions candidate, sensitivity added.** The audit computed an
   upper 95 % bound on each stratum's true SD (5 df,
   `s · sqrt(5/0.8312) ≈ 2.453·s`) and re-ran `h(n)` on that bound:
   smallest `n` becomes 3 (L0), 3 (L1), **4** (L2/50 ms, up from the
   point-estimate's 3), 2 (L2/500 ms) — largest **4**, not 3, under this
   more conservative view. Reported as a sensitivity on the point
   estimate, not a replacement for it, and not a change to the
   pre-declared rule. Also flagged: a 2 pp *absolute* target is close to
   trivially satisfied once the fraction itself is under ~2 % (L1,
   L2/500 ms) — "meets 2 pp" should not be read as "precisely estimated"
   at those two strata.
6. **Counting-noise cross-check (new, from the audit, re-run and
   confirmed independently)**: every stratum's observed between-run SD,
   including the original 100 ms-interval L0/50 ms figure, is consistent
   with pure within-run binomial counting noise at that stratum's own
   sample count (e.g. L2/500 ms: binomial SD 0.105 pp vs. observed
   0.086 pp; L0/100 ms archive: binomial SD 1.33 pp vs. observed
   1.779 pp — both within the expected χ²(5) range). This directly
   (though only approximately, ignoring within-run autocorrelation)
   supports the repeated caution in this document that the 100 ms-vs-
   20 ms SD gap may be substantially a sample-count artifact rather than
   a real difference in physical variability — still not fully resolved,
   but no longer merely asserted as a possibility.

All six corrections independently re-verified by the coordinator against
the raw files before being written here (not accepted on the audit's
assertion alone): `unsent_nonempty_count`/`mech_unsent_pending` equality
for both cited runs; the host-CSV dip values and the exact `hostmon.csv`
rows for both flagged L1 attempts; `pilot20_L1_r50_4`'s sample-count
deficit and `gap_max_ticks`.

## Full 24-attempt window-sensitivity recheck (2026-10-08)

The `[3,30)`/`[30,60)` sensitivity comparison had only been spot-checked
on 3 of 24 attempts. Extended to all 24 (`experiment-engineer`,
coordinator-spot-verified on `pilot20_L1_r50_3`'s `[30,60)` cell,
reproduced exactly: n=1465, 0.478%). These are overlapping windows of
the SAME run, not independent replications — not counted toward any n.

| run_id | `[3,30)` % | `[30,60)` % | `[3,60)` % |
|---|---|---|---|
| `pilot20_L0_r50_1` | 3.185 | 3.267 | 3.228 |
| `pilot20_L0_r50_2` | 3.037 | 3.600 | 3.333 |
| `pilot20_L0_r50_3` | 3.704 | 3.800 | 3.754 |
| `pilot20_L0_r50_4` | 2.074 | 3.800 | 2.982 |
| `pilot20_L0_r50_5` | 3.111 | 3.200 | 3.158 |
| `pilot20_L0_r50_6` | 3.333 | 3.467 | 3.404 |
| `pilot20_L1_r50_1` | 1.704 | 1.400 | 1.544 |
| `pilot20_L1_r50_2` | 1.259 | 0.867 | 1.053 |
| `pilot20_L1_r50_3` | 1.037 | 0.478 (n=1465) | 0.746 (n=2815) |
| `pilot20_L1_r50_4` | 1.634 (n=1346) | 0.938 (n=1493) | 1.268 (n=2839) |
| `pilot20_L1_r50_5` | 1.259 | 1.201 (n=1499) | 1.229 (n=2849) |
| `pilot20_L1_r50_6` | 1.259 | 0.733 | 0.982 |
| `pilot20_L2_r500_1` | 0.519 | 0.267 | 0.386 |
| `pilot20_L2_r500_2` | 0.444 | 0.200 | 0.316 |
| `pilot20_L2_r500_3` | 0.593 | 0.267 | 0.421 |
| `pilot20_L2_r500_4` | 0.370 | 0.000 | 0.175 |
| `pilot20_L2_r500_5` | 0.222 | 0.333 | 0.281 |
| `pilot20_L2_r500_6` | 0.370 | 0.267 | 0.316 |
| `pilot20_L2_r50_1` | 4.074 | 3.469 (n=1499) | 3.756 (n=2849) |
| `pilot20_L2_r50_2` | 3.852 | 3.867 | 3.860 |
| `pilot20_L2_r50_3` | 4.370 | 2.667 | 3.474 |
| `pilot20_L2_r50_4` | 4.593 | 4.467 | 4.526 |
| `pilot20_L2_r50_5` | 3.111 | 4.467 | 3.825 |
| `pilot20_L2_r50_6` | 4.074 | 4.867 | 4.491 |

`n[30,60)` is below the nominal 1500 only for `pilot20_L1_r50_3/4` and
`pilot20_L2_r50_1` — the same sample-count deficits already on record
above (gap/drop effects on `L1_r50_3/4`; a similar small deficit on
`L2_r50_1`), not a new finding. No qualitative regime change is visible
between half-windows at any of the 24 attempts beyond ordinary
run-to-run noise. No new exclusion gate is proposed from this.

**`pilot20_L0_r50_1`'s overrun — command-level cause, not just outcome
consistency.** Quoted directly from the attempt's own `.execution.log`:

> "ROOT CAUSE: this is a control-loop timing defect in my own execution,
> not a platform/instrumentation anomaly. I sent `iperf -c` at 20:40:13Z
> intending to wait exactly 60s before stopping it, but the actual wait
> procedure (a background `sleep 62` task plus several intervening tool
> round-trips while polling for its completion) consumed additional
> wall-clock time before I sent `iperf --stop` at 20:41:41Z -- 88 seconds
> after the client started, not 60."

The log attributes the overrun to polling-loop/tool-round-trip overhead
layered on top of an intended ~60s wait, not to a specific wrong sleep
duration — it does not quantify how much of the extra ~28s came from
which source, and none is inferred beyond that here. Independently
re-confirmed that the stratum table uses the correct, predeclared `[3,60)`
value for this attempt (3.228%) and not the whole-run accumulator's
value (`mech_app_limited`/`sample_count` = 137/4395 = 3.117%, a different
number) — the existing record did not substitute the wrong figure.

**L1 anomalous runs' eligibility**, checked against this plan's own
completeness/identity requirements, independent of N8's verdict:
both `pilot20_L1_r50_3` and `pilot20_L1_r50_4` have zero stale samples,
a fully-written trace matching `sample_count` exactly, a `run_id` in the
JSON matching the requested run_id exactly, and a single unambiguous
host connection with a port/timestamp/run_id correspondence leaving no
positional-index ambiguity. `pilot20_L1_r50_4`'s small sample deficit
(2989 vs. 2994 expected, 0.17%) sits under `GATE_DRIFT_FRAC=0.5%`, and
its `gap_max_ticks=4` sits at (not over) `GATE_GAP_FACTOR=2`'s threshold
— neither would fire the timing-drift gate. Both runs are eligible by
the plan's own completeness/identity bar; the host-scheduling anomaly is
recorded as coincident with the throughput dip (per `hostmon.csv`), not
upgraded to an assigned unique cause beyond what that correlation
supports.

## N8/scientific-validity implementation (2026-10-08)

Implemented in `collect_run_meta.sh` (only tracked file changed) per
`11_open_problems.md`'s N8 entry (RESOLVED) — see that entry and the
script's own header comment for the full design. Independently verified
by the coordinator against **real** archived data, not just the
implementing agent's synthetic fixtures: running the updated script
against `b1_capture/b1_load_4.json` + `host_load.csv` (the actual
"run median is zero" case) gives `valid=yes`, `validity_class=VALID_ANOMALOUS`,
`n8_verdict=INSUFFICIENT`, `n8_reason="run median is zero"`,
`invalid_reason` empty, `anomaly_reason` populated — confirming the
intended behavior change on a real, not synthetic, run. `interval_gate.py
selftest` re-run afterward (that file was not modified) reproduces
exactly its prior output, including the two known, intentional
`INSUFFICIENT`-vs-`INVALID` FAILs on B1 LOAD 4/5 — nothing regressed.
