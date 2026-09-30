# 08 — Design Rationale

Why the design is what it is. Written so a future session
reconstructing state from the repository does not revert to an
earlier framing.

## Why not "effect of the three parameters on throughput"

The earlier framing compared TCP_SND_BUF, TCP_SND_QUEUELEN and
MEMP_NUM_TCP_SEG as co-equal factors. It was abandoned because the
answer is foreclosed by the constraints in F32:

    TCP_SND_QUEUELEN  >= 2 * TCP_SND_BUF / TCP_MSS
    MEMP_NUM_TCP_SEG  >= TCP_SND_QUEUELEN

At the baseline (8196/22/40), expected queue occupancy under
full-MSS segmentation is ~5.6 pbufs against a limit of 22, and the
segment pool sits higher still. Both resources are provisioned
above the byte buffer by construction. Raising them further — the
C and D arms — moves an already-unreachable ceiling further away.
The expected result is null, and the nullity is derivable from
opt.h without running anything.

## What replaced it

Mechanism attribution. The question is which sender-side mechanism
is active at each operating point, answered from internal PCB state
rather than from throughput correlation. That question is not
foreclosed: snd_buf occupancy, cwnd and snd_wnd are runtime values
that no source reading determines.

TCP_SND_BUF remains in the design as the probe, not the subject: it
is the only sender-side capacity the application can set, so
varying it is the only available way to change configured capacity
and observe how the runtime state responds.

## Why QUEUELEN and MEMP_NUM_TCP_SEG are pinned, not varied

Pinning both at 44 (the minimum required by L2 = 32768) makes
TCP_SND_BUF a genuine single factor across the whole ladder,
rather than only across the 8196->16384 step.

Evidence that they do not bind comes from two layers, which prove
different things and must not be conflated:

    Layer 1 (narrow) — pinning control, stock 8196/22/40 vs pinned
    8196/44/44 at two RTT points. Tests whether the pinned build
    behaves like the stock build. This is an EXTERNAL VALIDITY check:
    do findings transfer to a stock RT-Thread configuration? It
    cannot show that pinning is harmless everywhere, and is not
    asked to.

    Layer 2 (complete) — snd_queuelen high-water and segment-pool
    usage recorded at EVERY Phase 1 cell. If the high-water never
    approaches the limit, the queue did not bind anywhere. This is
    direct observation over the whole grid, not extrapolation from
    a sample. This is the load-bearing evidence.

Three claims that must stay distinct in the thesis text:
  - "the pinned limit did not bind"      (Layer 2, complete)
  - "the stock limit would not have bound" (Layer 1, only where measured)
  - "pinning caused no observable perturbation at the tested points"
                                          (Layer 1, narrow)

Static cost of pinning (measured, not estimated): the TCP_SEG memp
pool is exactly 60 bytes per segment.
memp_memory_TCP_SEG_base is 0x963 = 2403 bytes at SEG=40 and
0xa53 = 2643 bytes at SEG=44 (= num*60 + 3 alignment bytes in both
cases). Pinning therefore costs 240 bytes of BSS against a 64 MB
heap region. Note that `size`-reported total BSS does NOT move
(114284 bytes at both SEG=40 and SEG=44): section padding absorbs a
change this small, so `nm --size-sort -S` on the pool symbol is the
correct instrument and `size` on the ELF is not. This supersedes the
earlier "+16384-byte BSS jump between SEG=60 and SEG=80" figure,
which was a page-rounding artefact of reading `size` output.

## Why the ladder is three points

Two points show a direction; three can show whether the
relationship is sustained, saturating, or non-monotonic.

Ladder rule (why each point, not "powers of two"):
    L0 = 8196  — the shipped baseline; anchors results to stock.
    L1 = 16384 — doubling; tests whether throughput responds to
                 capacity at all.
    L2 = 32768 — largest reachable point; tests whether the response
                 persists across the range.

In application-write units (IPERF_BUFSZ = 4096, F14) the ladder is
2 -> 4 -> 8 writes per buffer. At L0 the buffer holds two writes,
so occupancy moves in coarse 4096-byte steps.

Ceiling: L2 is not chosen, it is imposed. 65536 truncates to 0 in
the u16_t snd_buf field (F33), and LWIP_WND_SCALE = 0 (F06) caps
snd_wnd at 65535 regardless of what the peer advertises. The
maximum sustainable outstanding data in this configuration is
therefore ~64 KB.

All three points were built and macro-dump-confirmed at 44/44 on
2026-09-29, zero warnings, iperf linked exactly once each
(raw_logs/build_L{0,1,2}.log, raw_logs/macro_dump_L{0,1,2}.txt).
Note that 32768 builds cleanly once TCP_SND_QUEUELEN is raised to
44; its earlier rejection was an artefact of holding QUEUELEN at 22,
not a property of the value itself.

## Coupled parameter: TCP_SNDLOWAT — traced, NOT operative

TCP_SNDLOWAT = TCP_SND_BUF / 2 (F16, lwipopts.h:395), so it moves
with the ladder: 4098 / 8192 / 16384. In application-write units:
1.0 / 2.0 / 4.0. The ladder therefore varies buffer capacity and
refill threshold together.

This was flagged as a possible confound and has now been traced.
It is NOT one. Every reference to TCP_SNDLOWAT and
TCP_SNDQUEUELOWAT in the compiled sources is either a compile-time
sanity check (init.c:310, 313, 316) or a select()/poll() writability
notification:

    api_msg.c:330-331  poll_tcp   -> clears NETCONN_FLAG_CHECK_WRITESPACE,
                                     fires API_EVENT(NETCONN_EVT_SENDPLUS).
                                     Reached only if a NON-BLOCKING write
                                     previously failed (that flag is set
                                     only in the dontblock branch).
    api_msg.c:364-365  sent_tcp   -> same SENDPLUS notification. The actual
                                     blocking-write continuation on this
                                     path is lwip_netconn_do_writemore()
                                     at api_msg.c:356, called
                                     UNCONDITIONALLY when state ==
                                     NETCONN_WRITE. It does not consult
                                     TCP_SNDLOWAT.
    api_msg.c:1565-6   do_writemore -> fires API_EVENT(SENDMINUS) only;
                                     control flow continues to the
                                     err == ERR_OK branch regardless.

The blocking write path's real flow control is tcp_write() returning
ERR_MEM on snd_buf / snd_queuelen exhaustion, after which the writer
waits for sent_tcp or poll_tcp to resume it. TCP_SNDLOWAT never
gates, delays or shortens a blocking write.

netutils-iperf uses plain blocking send() and never calls select(),
so the API_EVENT notifications have no consumer in this experiment.

Consequence: a fixed-TCP_SNDLOWAT arm is EXCLUDED, not post-data.
There is no mechanism by which it could affect the measurement.
(Note also that the RT-Thread port's plain (TCP_SND_BUF/2) drops the
clamping lwIP's own opt.h:1221 default applies; at every ladder point
the two happen to agree, so this is a portability note, not a defect.)

## The sampling instrument: why a periodic soft timer

This section exists because it was missing. The sampler was designed and
built against a specification that lived only in a chat message and was
recorded nowhere in the repository, while `02_experiment_history.md`
Event 18 simultaneously stated that no periodic sampler had been
designed. A future session reading 08 would have found the single point
of failure named in this document's last paragraph with no design behind
it. The validated design follows. Implementation:
`bsp/qemu-vexpress-a9/applications/instr.c`; de-risking evidence:
`09_sampler_derisk.md`.

Under mechanism attribution the sampler is not instrumentation attached
to the experiment, it IS the experiment: the joint state of snd_buf /
unsent / cwnd / snd_wnd is the primary evidence and nothing else
produces it. So the trigger has to satisfy one hard requirement that an
ordinary debug hook does not: **the sampling instants must be
independent of the process being measured.** Every rejection below
follows from that.

### Why tcp_poll was rejected: it produces zero samples under load

DISPROVEN EMPIRICALLY AND FROM SOURCE. `pcb->polltmr` is reset to 0 on
every processed ACK (`core/tcp_in.c:1203`, inside `tcp_receive()`'s
forward-progress handling). The poll callback fires only when `polltmr`
reaches `pcb->pollinterval`, so a continuously-ACKed bulk transfer never
lets it accumulate. A 30 s live transfer produced `sample_count=0`; a
temporary trace inside `tcp_slowtmr()` showed `polltmr` pinned at 1
forever. `tcp_poll` is an idle-connection callback by design, not a
clock. Full account: `02_experiment_history.md` Events 14-17,
`01_verified_facts.md` F27-F28.

### Why tcp_sent was rejected: rate-correlated, phase-biased sampling

This is the more instructive rejection, because `tcp_sent` *does* fire
during a bulk transfer — it looks like a working sampler and is not one.
Two independent defects, both source-verified:

1. **Sampling rate is proportional to the measured quantity.**
   `TCP_EVENT_SENT` is invoked at `core/tcp_in.c:402`, inside ACK
   processing, and only when `recv_acked > 0`. Its firing rate is
   therefore the ACK arrival rate, which is the throughput. A
   high-throughput cell would be sampled many times more densely than a
   low-throughput one, so every per-cell mean would be weighted by the
   very variable the experiment varies (RTT, via throughput). Sample
   counts would also stop being a validity check, because the expected
   count would no longer be derivable from duration and interval.

2. **Samples land at a privileged phase of the buffer cycle.**
   `pcb->snd_buf += recv_acked` executes at `core/tcp_in.c:1248` inside
   `tcp_receive()`, which returns *before* `tcp_input()` reaches the
   `TCP_EVENT_SENT` call at line 402. The callback therefore always
   observes `snd_buf` immediately after it was replenished — the
   emptiest-buffer moment of each cycle is systematically excluded. For
   a study whose question is literally "is the send buffer
   under-occupied", sampling only the post-refill phase would bias the
   headline statistic in the direction of the answer.

Separately, `pcb->sent` is a single slot already occupied by
`api_msg.c`'s `sent_tcp`, which drives `lwip_netconn_do_writemore()` —
the blocking-write continuation. Instrumentation there sits directly in
the write path.

### Why a soft timer, and why not a hard timer

`RT_TIMER_FLAG_SOFT_TIMER | RT_TIMER_FLAG_PERIODIC`. The timer's phase is
set by `rt_timer_start()` and advances on the system tick
(`RT_TICK_PER_SECOND` = 100, so 10 ms resolution), with no dependency on
packet arrivals, ACKs, lwIP's TCP timers, or the application's write
loop. That is the independence requirement, met structurally rather than
argued.

A **hard** timer was rejected: its callback runs in tick ISR context,
where blocking on `lock_tcpip_core` is not permitted, and the callback
cannot safely read pcb state without that lock. A soft timer runs on
RT-Thread's timer thread (priority 4, 4096-byte stack,
`rtconfig.h:77-78`), which may block. That thread is higher priority than
`tcpip_thread` (10) and the iperf thread (20); RT-Thread mutexes
implement priority inheritance (`src/ipc.c`), so a lower-priority lock
holder is boosted rather than starved.

The timer object is created once at `INIT_APP_EXPORT` time and only
started and stopped thereafter, so arming and disarming never allocate
and cannot fail partway.

### Why the pcb->poll chaining was removed rather than ported

The `tcp_poll` design chained: save `pcb->poll`, install the sampler,
call the saved callback through. With the timer there is no reason to
touch `pcb->poll` at all, and not touching it is a strictly stronger
"do not modify the data path" guarantee than chaining. It also deletes a
real latent bug: the chaining `instr_detach_client_socket()` re-resolved
fd to pcb and **returned early when that failed**, leaving
instrumentation installed in `pcb->poll` — and resolution fails exactly
when the socket is being torn down abruptly, which is precisely when
detach matters.

### Why pointer validation needs the port pair, not just list membership

The timer thread holds a `struct tcp_pcb *` captured at attach, and the
connection can be closed and its pcb freed between two firings. The
callback therefore validates before dereferencing, under the core lock:

- **Membership in `tcp_active_pcbs`** establishes that the pointer is
  live *right now*. lwIP removes a pcb from that list
  (`TCP_RMV_ACTIVE` / `tcp_pcb_remove`) before returning its memory, so
  a pointer found in the list is safe to read while the lock is held.
- **Membership alone is insufficient**, and this is the non-obvious
  part. pcbs come from a fixed memp pool. A freed block can be handed
  straight back out for a *different* connection, which is then itself
  registered in `tcp_active_pcbs`. The stale pointer would pass the
  membership test and the sampler would silently accumulate another
  connection's state into this run's totals — a wrong number with no
  error, which is the worst failure mode available. Comparing
  `local_port` and `remote_port` against the pair recorded at attach
  makes that case detectable, because the replacement connection cannot
  reuse both ports.

Note what this does and does not prove. In every de-risking run
`stale_count` was 0 (`09_sampler_derisk.md`), so the guard has never
fired. It is UNEXERCISED, not shown unnecessary; the argument for it is
structural, not empirical.

### Lock discipline

In order: `LOCK_TCPIP_CORE()`; validate; copy the wanted fields into
plain locals, including the `unsent` walk, which is a pcb dereference and
so must happen inside the lock; `UNLOCK_TCPIP_CORE()`; then all
accumulator arithmetic. The invariant is two-sided and both halves
matter: **no pcb memory is dereferenced outside the lock** (correctness),
and **no accumulator arithmetic runs inside it** (the lock is held for a
bounded handful of loads, so the sampler cannot become a source of
contention that perturbs the thing it measures).

### The FLOOR/FULL switch and the runtime-tier deviation

`INSTR_WALK_SEGMENT_LISTS` remains the FLOOR/FULL switch. It gates
whether the `unsent`-list walk — the only part of a sample whose cost is
O(list length) rather than O(1) — is compiled in at all.

DESIGN DECISION, deviating from the original compile-time-only
specification: within a `=1` build, a runtime `instr_tier
<off|floor|full>` selects the tier. The reason is a confound, not
convenience. Comparing tiers by rebuilding means each tier is measured
in a different boot, so a tier difference is inseparable from
boot-to-boot differences in heap layout, ARP/route state, host-side
socket and port reuse, and QEMU/host load. The perturbation question
being asked — does sampling change the throughput it measures — is a
small-effect question, so a confound of unknown size sitting on top of it
is not acceptable. The runtime tier makes OFF/FLOOR/FULL interleavable
within one boot, which is the standard way to handle this and matches the
`run_ordering.randomize_within_block` discipline already in
`manifest.yaml`.

`off` **does not start the timer at all**, rather than starting it and
returning early from the callback. Otherwise the OFF arm would still
carry soft-timer thread wakeups and scheduler activity, and would measure
the marginal cost of the lock-and-copy instead of the cost of sampling.
The compile-time `=0` build is retained on top of this: it is the only
way to show the walk's *code* is absent, for a claim that does not rest
on trusting a runtime flag.

### The timing self-check

The sampler records `first_sample_tick`, `last_sample_tick` and
`sample_count`, and reports `sample_span_ticks`. Because the interval is
known and tick-quantised, the expected sample count is
`sample_span_ticks / interval_ticks + 1` exactly, so every run carries
its own arithmetic proof that the clock did not drift or stall — a
property `tcp_poll` and `tcp_sent` could not offer even in principle
(under `tcp_sent` the expected count is unknown; under `tcp_poll` it was
zero). At L0 / 50 ms this check was exact: 319 observed against 319
expected. `stale_count` separates "the timer did not fire" from "the
timer fired and the target was not valid", which are different faults
with different causes.

The tolerance that turns this self-check into an INVALID gate is
**TBD FROM PILOT** and is not set here. Per-sample gap extrema are
recorded so the tolerance can be chosen from measured jitter rather than
assumed.

## Excluded, with reasons

    Bottleneck-migration hypothesis  — premise foreclosed (above)
    C/D arms as experimental factors — subsumed by Layer 2 evidence
    BDP as an experimental target    — no enforced bottleneck bandwidth
    Artificial link rate limit       — adds a second candidate bottleneck
    Any fitted model (eta, Delta)    — no evidence for any functional form
    Write size as a factor           — fixed at 4096, documented
    Fixed-TCP_SNDLOWAT arm           — traced, not operative (above)
    Symmetric-delay switch           — one-sided retained, documented as
                                       a limitation; RTT is what the
                                       mechanism depends on, not its
                                       distribution between directions

## The design survives a boring result

If throughput falls with RTT as expected, larger buffers help
proportionally, nothing migrates and no residual needs explaining,
the deliverables in 06_thesis_candidates.md still stand: the
truncation hazard, the structural configuration result, the
instrumentation methodology including the tcp_poll finding,
mechanism attribution (reporting whatever was active), quantified
RTT sensitivity, and provisioning guidance bounded by the 64 KB
ceiling. None of these depends on an interesting outcome.

The single point of failure is instrumentation. Without working
in-transfer sampling there is no attribution, and Phase 1 degrades
to a throughput sweep.
