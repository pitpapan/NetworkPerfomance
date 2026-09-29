# TFG Handoff — Read This First

> Repository/source/build/runtime evidence is authoritative.
> This handoff is a secondary index to that evidence.
> Claims marked `SESSION-DERIVED` require preservation or re-verification before being used as final thesis evidence.

Full detail lives in the numbered files in this directory (`00_project_state.md` … `07_reproduction_notes.md`). This file is the map, not the territory.

---

## 1. What is the thesis about?

The effect of sender-side TCP resource configuration — `TCP_SND_BUF`, `TCP_SND_QUEUELEN`, `MEMP_NUM_TCP_SEG` — on RT-Thread/lwIP bulk TCP throughput, measured across a range of fixed, one-sided network delays (RTT points). System under test: RT-Thread 5.3.0 + lwIP 2.0.3 on QEMU `vexpress-a9`, transferring data to a Ubuntu host over a TAP link with `netem`-injected delay. See `00_project_state.md`.

## 2. What has actually been verified?

Extensive **source-level and build-level** verification of the platform (35 numbered facts in `01_verified_facts.md`), including exact effective values of every relevant lwIP macro, PCB field types, the byte-vs-segment denomination of `cwnd`, the full set of compile-time sanity checks, thread priorities, and the socket→PCB access path. All of this is re-checkable right now from the current tree — it does not depend on this conversation.

**Zero throughput/RTT results have been formally verified.** No run has ever gone through the 5-repetition, validity-gated protocol.

## 3. What Phase-0 results already exist?

Source/config verification (P0-A) is essentially complete and solid — see `03_phase0_results.md`. Preliminary/pilot throughput numbers exist (P0-C-preliminary) but are all single, unrepeated, weakly-provenanced observations — none are dataset-eligible.

## 4. Which historical measurements are unreliable?

**All of them, for the final dataset.** See `04_historical_measurements.md` for the full table. Three numbers the user specifically asked to preserve — **≈1.07 Mbps at ≈100ms, an "RTT≈0" measurement, and ≈29–40 Mbps platform measurements** — could **not be located** in this session's visible context and are recorded as `PROVENANCE INSUFFICIENT`. They are preserved as asserted, not confirmed. Do not build thesis claims on them without first finding or re-deriving their origin.

The best-provenance pilot figure is: baseline config (boot-banner-confirmed 8196/22/40), `netem delay 50ms` (qdisc-confirmed), RT-Thread→Ubuntu direction, self-reported ≈1.24–1.25 Mbps, repeated across ≥3 ad hoc 30s runs — still PILOT ONLY, not final.

## 5. What experimental design is currently accepted?

- Direction: **RT-Thread → Ubuntu only** (sender-resource isolation rationale — see `02_experiment_history.md` Event 4).
- 6 TCP configs: BASE(8196/22/40), B1(16384/22/40), C1(8196/30/40), C2(8196/40/40), D1(8196/22/60), D2(8196/22/80) — all individually build-verified.
- 4 RTT points: 50/100/200/500ms.
- 5 repetitions/cell, 120 total planned runs.
- Recorded in `bsp/qemu-vexpress-a9/experiment/manifest.yaml` and `run_matrix.csv` (all cells `pending`).
- `32768` and `65536` are explicitly **excluded** from the `TCP_SND_BUF` ladder — see item 6.

## 6. What failed and why?

The biggest methodological finding of this whole project: **`tcp_poll` cannot be used as a periodic sampler.** Its countdown resets to zero on every processed ACK (`tcp_in.c:1203`), so during a continuous bulk transfer it essentially never fires — empirically confirmed with a live 30-second transfer producing `sample_count=0`. This was root-caused precisely (not guessed): a temporary debug trace inside lwIP's own `tcp_slowtmr()` showed the poll counter pinned at 1 forever; grepping every write site for `polltmr` found the ACK-triggered reset. The trace was fully reverted afterward (`tcp.c` is byte-identical to HEAD).

Also failed/rejected along the way, each for a documented reason (`05_invalid_superseded_claims.md`):
- NetIO as the benchmark (superseded by netutils iperf, found via a separate un-merged branch).
- A naive 2-level fd→pcb translation (missing a DFS/vnode indirection layer — fixed to 3 levels).
- A naive `tcp_poll()` registration that would have replaced lwIP's own write-retry callback (caught by source review *before* running, replaced with a chaining design).
- A planned `MEM_SIZE` A/B runtime test — correctly cancelled before running once source proved `MEM_SIZE` is dead config in this port (`mem_malloc`→`rt_malloc`).
- `TCP_SND_BUF=32768` (build fails, hard `#error`) and `=65536` (builds, but GCC proves it truncates to 0 at runtime) — both excluded from the ladder.

## 7. What is the next concrete task?

**Design and implement a periodic, ACK-independent sampler** to replace `tcp_poll` as the in-transfer sampling trigger, before any instrumented Phase 1 run can produce useful sender-state data. This was identified but explicitly **not designed** in this session (see `02_experiment_history.md` Event 18) — do not assume a design exists. Candidate directions to evaluate: a dedicated RT-Thread software timer independent of lwIP's TCP timers, or hooking a different already-occupied callback (`tcp_sent`) with the same chaining discipline used for `tcp_poll`. Whatever is chosen must preserve the "do not modify the data path" constraint the same way the current `tcp_poll` chaining does.

After that: execute the actual 120-run Phase 1 sweep using `experiment/run_matrix.csv` and the helper scripts in `experiment/scripts/`.

## 8. What must not be rediscovered or accidentally reverted?

- Do not re-introduce `snd_una` as a field name — it doesn't exist; use `lastack`.
- Do not call `tcp_poll()` directly on an active netconn-backed pcb without chaining — it will silently replace lwIP's own `poll_tcp` and degrade the write-retry/close-wait mechanism.
- Do not raise `TCP_SND_BUF` above 65535 without also reconsidering `LWIP_WND_SCALE` — it will compile and silently misconfigure.
- Do not lower `TCP_SND_QUEUELEN` below `2*TCP_SND_BUF/TCP_MSS`, or `MEMP_NUM_TCP_SEG` below the active `TCP_SND_QUEUELEN` — both are hard build failures, not soft warnings.
- Do not emit a single `rt_kprintf()` call longer than ~255 bytes — it will be silently truncated (`RT_CONSOLEBUF_SIZE=256`).
- Do not treat any number in `04_historical_measurements.md` as a final result — all are PILOT ONLY or worse.
- Do not lose the uncommitted changes listed in `07_reproduction_notes.md` (`sockets.c`/`sockets.h`/`instr.c`/`instr.h`, plus the untracked `iperf.c` hook under gitignored `packages/`) — none of this is committed to git as of HEAD `fc586d5`.
