# 09 — Periodic Sampler: Implementation and De-Risking Results

Session date: 2026-09-29 (later than the `00`–`08` archival pass).
Scope: replace the rejected `tcp_poll` sampling trigger (`02_experiment_history.md`
Events 15–18) with a periodic, ACK-independent one, and de-risk it. **No Phase 1
cell was run. No repetition count, duration, discard window or threshold was set.
Numbers below are reported as observed and are not interpreted.**

## What was implemented

`applications/instr.c`, `applications/instr.h`. The boot banner, 3-level
fd→pcb translation, accumulators and msh commands are unchanged in purpose.
The sampling **trigger** was replaced:

- An RT-Thread software timer, `RT_TIMER_FLAG_SOFT_TIMER | RT_TIMER_FLAG_PERIODIC`,
  created once at `INIT_APP_EXPORT` time (`instr_timer_init`) so attach/detach
  never allocate. Runs on the soft-timer thread: priority 4, 4096-byte stack
  (`rtconfig.h:77-78`).
- **The `pcb->poll` chaining is removed entirely.** lwIP's own `poll_tcp`
  (installed by `api_msg.c`'s `setup_tcp()` for `ERR_MEM` write retries and
  close-wait) is never read, replaced or restored. This is a stronger
  "do not modify the data path" guarantee than chaining was, and it removes the
  failure mode the chaining design had: the old `instr_detach_client_socket()`
  returned early if `fd`→`pcb` could no longer be resolved, which left
  `pcb->poll` still pointing at instrumentation.
- Callback discipline, in order: take `LOCK_TCPIP_CORE()`; validate the saved
  `pcb` pointer by searching lwIP's own `tcp_active_pcbs` list **and** checking
  the `local_port`/`remote_port` pair recorded at attach (the list membership
  test alone is insufficient — a freed pcb's memp block can be recycled for a
  different connection at the same address); copy the wanted fields into plain
  locals, including the `unsent` walk, which is a pcb dereference and so must
  happen here; `UNLOCK_TCPIP_CORE()`; only then do all accumulator arithmetic.
  No pcb memory is dereferenced outside the core lock, and no accumulator
  arithmetic runs while holding it.
- `INSTR_WALK_SEGMENT_LISTS` is retained as the FLOOR/FULL switch. It now gates
  whether the walk is *compiled in*; a runtime `instr_tier <off|floor|full>`
  selects the tier within a `=1` build, so an OFF/FLOOR/FULL comparison can be
  interleaved inside one boot instead of requiring a rebuild per tier.
  **`off` does not start the timer at all** — no soft-timer wakeups, no core-lock
  acquisitions — so the OFF arm is a genuine no-instrument baseline.
- New per-run fields: `first_sample_tick`, `last_sample_tick`,
  `sample_span_ticks`, `stale_count` (timer fired, pcb failed validation), plus a
  `sampler` block recording `interval_ms`, `tier`, `walk_compiled` and
  `tick_per_second`, and `snd_buf_max`.
- Interval is msh-settable with no rebuild: `instr_interval <ms>`. Applied
  immediately if the sampler is already running. Floor of one tick
  (10 ms at `RT_TICK_PER_SECOND=100`).

Build: L0 = 8196/44/44, boot-banner-confirmed, zero warnings, `iperf` linked
exactly once. `text=764523 data=34272 bss=114300`. Log: `raw_logs/build_L0_sampler.log`.

## Item 2 — safe-shutdown tests (all three PASSED)

Conditions for all three: L0, `netem delay 50ms` (qdisc-confirmed, 0 dropped /
0 overlimits), RT-Thread→Ubuntu, GNU iperf 2.1.9 host server on port 5001,
sampler interval 100 ms, tier `full`.

| Test | Action | Result |
|---|---|---|
| 2a | clean `iperf --stop` after ~14 s | No crash. `sample_count=137`, `stale_count=0`. msh responsive. |
| 2b | host `iperf -s` killed (`SIGKILL`) mid-transfer | No crash. RT-Thread logged `[W/iperf] Disconnected` then `[E/iperf] Connect to iperf server faile`, i.e. `iperf.c`'s own retry loop, which is its normal behaviour. `sample_count=80`, `stale_count=0`. msh responsive; `free` reported used=34832 of 66109728. |
| 2c | 4 consecutive attach/detach cycles, ~6 s each | No crash. `sample_count=237` accumulated across the four cycles, `stale_count=0`. `sample_span_ticks=3588` (35.9 s wall) against ~24 s of transfer, confirming the timer was stopped during the inter-run gaps rather than sampling them. `free` used=35560, i.e. +728 bytes over 2b. |

`stale_count` was 0 in every test, so the validation path was never observed
rejecting a pcb. That means the recycling guard is untested by these runs, not
that it is unnecessary.

## Item 3 — validation run `val01` (PASSED)

L0, `netem delay 50ms`, interval 100 ms, tier `full`. Host ping immediately
before: min 50.577 / avg 51.265 / max 52.797 / mdev 0.630 ms, n=10, 0% loss.
qdisc before and after: clean netem, delay 50ms, 0 dropped / 0 overlimits /
0 requeues / 0 backlog (`raw_logs/sampler_validation_val01_qdisc_{pre,post}.txt`).

Verbatim `instr_dump`:

```
{"run_id":"val01","cfg":{"TCP_MSS":1460,"TCP_SND_BUF":8196,"TCP_SND_QUEUELEN":44,
"MEMP_NUM_TCP_SEG":44,"TCP_WND":2048,"TCP_OVERSIZE":1460,"TCP_SNDLOWAT":4098,
"TCP_SNDQUEUELOWAT":22,"LWIP_WND_SCALE":0},"sampler":{"kind":"soft_timer_periodic",
"interval_ms":100,"tier":2,"walk_compiled":1,"tick_per_second":100},
"sample_count":319,"stale_count":0,"first_sample_tick":17386,"last_sample_tick":20566,
"sample_span_ticks":3180,"snd_buf_min":0,"snd_buf_max":2936,"snd_buf_low_count":318,
"snd_buf_low_threshold":1024,"snd_queuelen_max":11,"cwnd_min":8760,"cwnd_max":65505,
"cwnd_mean_x1000":60710598,"snd_wnd_min":65535,"snd_wnd_max":65535,
"snd_wnd_mean_x1000":65535000,"inflight_min":5260,"inflight_max":8196,
"inflight_mean_x1000":8183774,"unsent_nonempty_count":0,"unsent_bytes_max":0,
"walk_segment_lists":1}
```

Host-side (authoritative): `4.77 MBytes / 31.9719 s = 1.25 Mbits/sec`.
RT-Thread self-reported per-5s interval: 1.2550 / 1.2450 / 1.2450 / 1.2530 /
1.2550 / 1.2510 Mbps.

Checks requested:

| Check | Value | Verdict |
|---|---|---|
| `snd_queuelen_max <= TCP_SND_QUEUELEN` | 11 <= 44 | PASS |
| `inflight_max <= snd_wnd_max` | 8196 <= 65535 | PASS |
| sample count vs span/interval | span 3180 ticks = 31.80 s; 31.80 s / 100 ms = 318 intervals = 319 sample instants inclusive; observed 319 | PASS, exact, zero drift |

## Item 4 — interleaved OFF/FLOOR/FULL, two full cycles

L0, `netem delay 50ms`, interval 100 ms, ~22 s per run, single boot, order
OFF→FLOOR→FULL twice. Host-side per-connection finals map 1:1 to runs in order
(`raw_logs/sampler_perturbation_item4_host_iperf.log`, connections 1–6).

| Run | Tier | Host bytes / duration | Host Mbits/sec | `sample_count` | `stale_count` |
|---|---|---|---|---|---|
| 1 | off   | 3.26 MBytes / 21.9125 s | 1.25 | 0 | 0 |
| 2 | floor | 3.25 MBytes / 21.9684 s | 1.24 | 217 | 0 |
| 3 | full  | 3.27 MBytes / 21.9916 s | 1.25 | 219 | 0 |
| 4 | off   | 3.27 MBytes / 21.9703 s | 1.25 | 0 | 0 |
| 5 | floor | 3.27 MBytes / 21.9981 s | 1.25 | 219 | 0 |
| 6 | full  | 3.27 MBytes / 21.9813 s | 1.25 | 219 | 0 |

Per tier (host-side Mbits/sec): OFF {1.25, 1.25}; FLOOR {1.24, 1.25};
FULL {1.25, 1.25}.

**No perturbation verdict is computed here.** n=2 per tier, and the host-side
figure is quantised to 3 significant figures, so these numbers are reported only
as the input a perturbation decision would need, not as that decision.

## Item 5 — NOT RUN

Repeating item 3 at `netem delay 500ms` requires `sudo tc qdisc replace`, and
`sudo` on this host requires an interactive password. `tap0` was left at
`delay 50ms`. The 500 ms low-throughput check on the timer is therefore still
open.

## Still unknown after this session

- Timer behaviour at 500 ms delay / low throughput (item 5, not run).
- Whether the `stale_count` validation path works: it never triggered
  (`stale_count=0` in all 11 runs), so the pcb-recycling guard is unexercised.
- `unsent_nonempty_count` was 0 in every run at L0/50 ms, so `unsent_bytes_max`
  and the whole FULL-tier walk are so far only shown not to crash, never shown
  to produce a non-zero value. The FLOOR/FULL distinction is consequently
  untested on its output, only on its cost.
- Sampling-interval choice, run duration, discard window, repetitions and
  `INSTR_SNDBUF_LOW_THRESHOLD` remain `TBD FROM PILOT` in `manifest.yaml`.
  Note that at L0/50 ms, `snd_buf_low_count` was 318 of 319 samples against the
  current 1024-byte default threshold, i.e. the threshold as it stands does not
  discriminate at this operating point.
