# TFG Handoff — Read This First

> Repository/source/build/runtime evidence is authoritative.
> This handoff is a secondary index to that evidence.
> Claims marked `SESSION-DERIVED` require preservation or re-verification before being used as final thesis evidence.

Full detail lives in the numbered files in this directory (`00_project_state.md` … `08_design_rationale.md`). This file is the map, not the territory. **If this file and `00`/`08` ever disagree about the design, `08_design_rationale.md` wins** — it exists specifically to stop the design drifting back to a superseded framing.

---

## 1. What is the thesis about?

**Which sender-side mechanisms limit bulk TCP throughput** in this RT-Thread/lwIP configuration, at each operating point across a range of fixed, one-sided network delays (RTT points). The evidence is the sender's own joint internal state — `snd_buf` occupancy, `unsent`, `cwnd`, `snd_wnd` — read from the TCP PCB during the transfer, not throughput correlation.

Configuration is the **probe, not the subject**. `TCP_SND_BUF` is varied because it is the only sender-side capacity the application can set; `TCP_SND_QUEUELEN` and `MEMP_NUM_TCP_SEG` are **pinned controls**, not factors.

> **Do not restate this as "the effect of the three parameters on throughput."** That earlier framing is superseded and was abandoned as foreclosed: lwIP's own compile-time coupling constraints (`TCP_SND_QUEUELEN >= 2*TCP_SND_BUF/TCP_MSS`, `MEMP_NUM_TCP_SEG >= TCP_SND_QUEUELEN`) mean the queue and segment resources are provisioned above the byte buffer by construction, so raising them further has a null answer derivable from `opt.h` without running anything. Full rationale in `08_design_rationale.md` — read it before touching the design.

System under test: RT-Thread 5.3.0 + lwIP 2.0.3 on QEMU `vexpress-a9`, transferring data to a Ubuntu host over a TAP link with `netem`-injected delay. See `00_project_state.md`.

## 2. What has actually been verified?

Extensive **source-level and build-level** verification of the platform (35 numbered facts in `01_verified_facts.md`), including exact effective values of every relevant lwIP macro, PCB field types, the byte-vs-segment denomination of `cwnd`, the full set of compile-time sanity checks, thread priorities, and the socket→PCB access path. All of this is re-checkable right now from the current tree — it does not depend on this conversation.

**Zero throughput/RTT results have been formally verified.** No run has ever gone through the formal, validity-gated protocol (`n` repetitions per cell, `n` TBD FROM PILOT).

## 3. What Phase-0 results already exist?

Source/config verification (P0-A) is essentially complete and solid — see `03_phase0_results.md`. Preliminary/pilot throughput numbers exist (P0-C-preliminary) but are all single, unrepeated, weakly-provenanced observations — none are dataset-eligible.

## 4. Which historical measurements are unreliable?

**All of them, for the final dataset.** See `04_historical_measurements.md` for the full table. Three numbers the user specifically asked to preserve — **≈1.07 Mbps at ≈100ms, an "RTT≈0" measurement, and ≈29–40 Mbps platform measurements** — could **not be located** in this session's visible context and are recorded as `PROVENANCE INSUFFICIENT`. They are preserved as asserted, not confirmed. Do not build thesis claims on them without first finding or re-deriving their origin.

The best-provenance pilot figure is: baseline config (boot-banner-confirmed 8196/22/40), `netem delay 50ms` (qdisc-confirmed), RT-Thread→Ubuntu direction, self-reported ≈1.24–1.25 Mbps, repeated across ≥3 ad hoc 30s runs — still PILOT ONLY, not final.

## 5. What experimental design is currently accepted?

- Direction: **RT-Thread → Ubuntu only** (sender-resource isolation rationale — see `02_experiment_history.md` Event 4).
- Primary independent variable: **RTT** — 4 points, 50/100/200/500 ms, one-sided `netem` on `tap0` egress (delays the returning ACKs in this direction).
- Secondary independent variable: **`TCP_SND_BUF`** — 3-point ladder **L0 = 8196, L1 = 16384, L2 = 32768**.
- **Pinned controls, identical in every build: `TCP_SND_QUEUELEN` = 44, `MEMP_NUM_TCP_SEG` = 44** (the minimum L2 requires). This makes `TCP_SND_BUF` a genuine single factor across the whole ladder instead of only across the 8196→16384 step. Their non-binding is established analytically from the constraints plus per-cell high-water marks — **not** by comparing arms.
- **19 cells**: 12 `main` (3 × 4), 3 `platform` (ladder at RTT≈0, reported separately), 4 `pinctl` (STOCK 8196/22/40 vs PINNED 8196/44/44 at 50 and 500 ms).
- **Repetitions `n` are TBD FROM PILOT** — deliberately blank in `run_matrix.csv`, to be set from the noisiest pilot cell rather than assumed.
- All four builds (L0/L1/L2/STOCK) are build-verified with archived logs and macro dumps: `raw_logs/build_{L0,L1,L2,STOCK}.log`, `raw_logs/macro_dump_{L0,L1,L2,STOCK}.txt`.
- `65536` is excluded from the ladder (u16_t truncation to 0 — item 6). **`32768` is NOT excluded**: it is ladder point L2 and builds cleanly at QUEUELEN=44. Its earlier rejection was an artifact of holding QUEUELEN at 22.
- Recorded in `bsp/qemu-vexpress-a9/experiment/manifest.yaml` and `run_matrix.csv` (all cells `pending`).

> **Superseded, do not reinstate:** the former 6-config × 4 RTT × 5 rep = 120-run matrix (BASE/B1/C1/C2/D1/D2). Its C and D arms — 80 of the 120 runs — varied the now-pinned controls as factors.

## 6. What failed and why?

The biggest methodological finding of this whole project: **`tcp_poll` cannot be used as a periodic sampler.** Its countdown resets to zero on every processed ACK (`tcp_in.c:1203`), so during a continuous bulk transfer it essentially never fires — empirically confirmed with a live 30-second transfer producing `sample_count=0`. This was root-caused precisely (not guessed): a temporary debug trace inside lwIP's own `tcp_slowtmr()` showed the poll counter pinned at 1 forever; grepping every write site for `polltmr` found the ACK-triggered reset. The trace was fully reverted afterward (`tcp.c` is byte-identical to HEAD).

Also failed/rejected along the way, each for a documented reason (`05_invalid_superseded_claims.md`):
- NetIO as the benchmark (superseded by netutils iperf, found via a separate un-merged branch).
- A naive 2-level fd→pcb translation (missing a DFS/vnode indirection layer — fixed to 3 levels).
- A naive `tcp_poll()` registration that would have replaced lwIP's own write-retry callback (caught by source review *before* running, replaced with a chaining design).
- A planned `MEM_SIZE` A/B runtime test — correctly cancelled before running once source proved `MEM_SIZE` is dead config in this port (`mem_malloc`→`rt_malloc`).
- `TCP_SND_BUF=65536` — builds, but GCC proves it truncates to 0 at runtime; excluded from the ladder.
- `TCP_SND_BUF=32768` **at `TCP_SND_QUEUELEN=22`** — hard `#error`. Note this is a constraint failure, **not** a property of the value: at the pinned QUEUELEN=44 it builds cleanly and is ladder point **L2** (`raw_logs/build_L2.log`). It is no longer excluded.

## 7. What is the next concrete task?

**Design and implement a periodic, ACK-independent sampler** to replace `tcp_poll` as the in-transfer sampling trigger, before any instrumented Phase 1 run can produce useful sender-state data. This was identified but explicitly **not designed** in this session (see `02_experiment_history.md` Event 18) — do not assume a design exists. Candidate directions to evaluate: a dedicated RT-Thread software timer independent of lwIP's TCP timers, or hooking a different already-occupied callback (`tcp_sent`) with the same chaining discipline used for `tcp_poll`. Whatever is chosen must preserve the "do not modify the data path" constraint the same way the current `tcp_poll` chaining does.

After that: execute the Phase 1 sweep over the **19 cells** in `experiment/run_matrix.csv` using the helper scripts in `experiment/scripts/` (`set_config.sh` to build and verify a configuration, `set_netem.sh` to apply and verify a delay, `collect_run_meta.sh` to record each run).

Note that `collect_run_meta.sh` now gates any run with `instr_sample_count == 0` as INVALID, so a sampler-less throughput-only sweep cannot be silently recorded as data. That is deliberate: under the mechanism framing the sampler is not a supplement, it is the instrument that produces the primary evidence.

## 8. What must not be rediscovered or accidentally reverted?

- Do not re-introduce `snd_una` as a field name — it doesn't exist; use `lastack`.
- Do not call `tcp_poll()` directly on an active netconn-backed pcb without chaining — it will silently replace lwIP's own `poll_tcp` and degrade the write-retry/close-wait mechanism.
- Do not raise `TCP_SND_BUF` above 65535 without also reconsidering `LWIP_WND_SCALE` — it will compile and silently misconfigure.
- Do not lower `TCP_SND_QUEUELEN` below `2*TCP_SND_BUF/TCP_MSS`, or `MEMP_NUM_TCP_SEG` below the active `TCP_SND_QUEUELEN` — both are hard build failures, not soft warnings.
- Do not emit a single `rt_kprintf()` call longer than ~255 bytes — it will be silently truncated (`RT_CONSOLEBUF_SIZE=256`).
- Do not treat any number in `04_historical_measurements.md` as a final result — all are PILOT ONLY or worse.
- The instrumentation (`sockets.c`/`sockets.h`/`instr.c`/`instr.h`) **is committed** as of `9b4178f` — earlier drafts of this file wrongly described it as uncommitted. The only artefact still at risk is the `iperf.c` hook under gitignored `packages/`, which is untracked and must be re-applied by hand if `packages/netutils-latest/` is re-cloned (see `07_reproduction_notes.md`).
- Do not vary `TCP_SND_QUEUELEN` or `MEMP_NUM_TCP_SEG` as experimental factors. They are pinned controls at 44/44. Reintroducing them as arms is the specific regression `08_design_rationale.md` exists to prevent.
- Do not edit `rtconfig.h` without `.config` (or vice versa). They disagreed on `TCP_WND` once already; `set_config.sh` now writes both and aborts on drift.
