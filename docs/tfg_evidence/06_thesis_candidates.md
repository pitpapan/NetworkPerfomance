# 06 — Thesis-Candidate Inventory

## Must appear in main thesis

| Claim | Evidence | Confidence | Proposed chapter | Risk of overclaiming |
|---|---|---|---|---|
| `TCP_SND_QUEUELEN` is auto-derived from `TCP_SND_BUF`/`TCP_MSS` by default in this lwIP port, and had to be explicitly decoupled to make it an independent variable | `01_verified_facts.md` F03; `lwipopts.h:386-390` | High | Methodology / Implementation | Low — directly observable in source, build-verified before/after |
| The `TCP_SND_QUEUELEN >= 2*TCP_SND_BUF/TCP_MSS` and `MEMP_NUM_TCP_SEG >= TCP_SND_QUEUELEN` constraints are hard, compiler-enforced (`#error`), not merely documented recommendations | `01_verified_facts.md` F32; reproduced with an actual failing build (`QUEUELEN=44`, `SEG=40`) | High | Methodology | Low |
| `TCP_SND_BUF` has an asymmetric lack of protection: `TCP_WND` and `TCP_SND_QUEUELEN` both have unconditional u16_t-fit compile-time checks, `TCP_SND_BUF` does not, and can silently truncate to 0 at runtime above 65535 | `01_verified_facts.md` F07, F32-F34; compiler warning observed live (text not archived, but mechanism and build success independently reproducible) | High (mechanism) / Medium (exact warning text, session-derived only) | Methodology / Threats to validity | Medium — must re-run and save the warning text before citing it verbatim in the thesis; the underlying type-chain fact is solid regardless |
| `tcp_poll` cannot serve as a periodic active-transfer sampler in this lwIP configuration because its countdown resets on every ACK | `01_verified_facts.md` F27-F28; `02_experiment_history.md` Events 14-17; empirically confirmed (`sample_count=0` after 30s) | High | Methodology (instrumentation design) | Low — both source and empirical evidence agree |

## Likely main thesis

| Claim | Evidence | Confidence | Proposed chapter | Risk of overclaiming |
|---|---|---|---|---|
| `cwnd` in this lwIP version is denominated in bytes, provable from the update code (`+= mss`) rather than the field name/documentation convention alone | `01_verified_facts.md` F09 | High | Background/lwIP internals | Low |
| The RT-Thread port replaces lwIP's private heap (`mem.c`/`MEM_SIZE`) with a direct passthrough to the RT-Thread kernel heap (`rt_malloc`) | `01_verified_facts.md`; `05_invalid_superseded_claims.md` #9 | High | Background / Platform description | Low |
| A 3-level fd indirection (POSIX/DFS fd → SAL socket index → lwIP internal fd) exists between the application socket API and the underlying `tcp_pcb`, with no single public accessor bridging all three | `01_verified_facts.md` F24-F26 | High | Implementation | Low |

## Appendix / reproducibility material

- Full baseline preprocessor macro dump (`docs/tfg_evidence/raw_logs/baseline_macro_dump_full.txt`)
- `experiment/manifest.yaml`, `run_matrix.csv`, and helper scripts (already in repo, `bsp/qemu-vexpress-a9/experiment/`)
- Exact `lwip_get_tcp_pcb()` diff (`sockets.c`/`sockets.h`)
- Full `applications/instr.c` source

## Methodology findings

- The single-slot nature of `tcp_poll`/`tcp_sent`/`tcp_recv`/`tcp_err` callbacks means any external instrumentation on an already-active netconn-backed pcb **must chain**, not replace, to avoid silently modifying the data path. This is a generalizable lesson for instrumenting any BSD-socket-backed lwIP connection, not specific to this TFG's parameters.
- `RT_CONSOLEBUF_SIZE=256` is a real practical ceiling on any single debug-output line on this board; multi-field JSON dumps must be split across calls.

## Candidate implementation findings (secondary, supporting material — not novel research contributions)

- The netem-egress-only delay mechanism causes an asymmetry in which TCP packet type (DATA vs ACK) is delayed, depending on transfer direction — relevant to interpreting *this* experiment's RTT semantics, not a general networking finding.
- The historical Git-archaeology process (NetIO → netutils iperf) is legitimate provenance documentation for *this* repository but is engineering/project history, not a research finding — keep it to a short methods/setup note, do not frame it as a contribution.

## Debugging only — do not include

- The exact sequence of failed `instr_pcb_from_fd()` attempts (2-level vs 3-level fd translation) — useful for `07_reproduction_notes.md` and for a future maintainer, not thesis material.
- The specific `TMRDBG`/temporary print statements used to diagnose `polltmr` behaviour (both were reverted; `tcp.c` is confirmed clean).
- Exact tmux/QEMU session management commands, `sudo` password handling, terminal capture quirks.

## Not yet supported (do not write as if proven)

- Any quantitative claim about how `TCP_SND_BUF`, `TCP_SND_QUEUELEN`, or `MEMP_NUM_TCP_SEG` actually affect throughput or RTT — **zero formal Phase 1 data exists**.
- Any claim using sampled `cwnd`/`snd_wnd`/in-flight values during an active transfer — the sampler that would produce this data has never successfully captured a sample during active transfer (`sample_count=0` in every attempt to date).
- Any specific numeric throughput value from `04_historical_measurements.md` as a *result* — all are PILOT ONLY or PROVENANCE INSUFFICIENT.
