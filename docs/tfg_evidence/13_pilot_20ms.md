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
