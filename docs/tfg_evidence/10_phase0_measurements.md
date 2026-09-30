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
