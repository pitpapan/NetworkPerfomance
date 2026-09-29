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
