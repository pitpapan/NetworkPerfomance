# 02 — Experimental History (Chronological, Scientifically Relevant Events Only)

This is a reconstruction from this session's own record of tool calls, source reads, builds, and runtime tests. It is not a full transcript. Where an event's only evidence is something observed in this conversation and not saved to a file, that is stated explicitly.

---

## Event 1 — Environment readiness baseline
**Prior belief:** none (first check of the session).
**Evidence:** host toolchain check, `scons -j2` build check, TAP/netem/benchmark-tool inventory.
**Result:** Build succeeded, but the firmware at that point contained **no compiled benchmark endpoint at all** (`examples/network/tcpclient.c` existed but was never wired into any SConscript); `tap0` had the default `fq_codel` qdisc, not `netem`.
**Consequence:** Established that benchmark restoration was needed before anything else.
**Current status:** SUPERSEDED (environment has since changed substantially).

---

## Event 2 — NetIO restoration, then reconsidered
**Prior belief:** unknown what benchmark tool the project originally used.
**Evidence:** Git history showed `5cccdd4`→`d722a4c`("added netio")→`2444f9a`("remove unused block", which actually deleted `netio.c`) → `2663d80` never restored it.
**Result:** `applications/netio.c` (nwlab.net NetIO protocol server) was restored byte-for-byte from commit `2444f9a` and built/linked successfully.
**Consequence:** Working benchmark endpoint existed, but no NetIO-speaking client tool exists on the host (neither `iperf` nor `iperf3` speaks that protocol).
**Current status:** SUPERSEDED — NetIO was later removed entirely once the netutils-iperf branch evidence was found (Event 3).

---

## Event 3 — Discovery of the real intended benchmark: netutils iperf
**Prior belief:** NetIO was the intended benchmark (based only on the `clean-benchmark` branch's own history).
**Evidence:** `origin/procotol` (a separate, never-merged remote branch) contains commit `ac28697` ("Parameters modifications") which enables `CONFIG_PKG_NETUTILS_IPERF=y`. Intermediate commits on that branch (`5fa2ee6` "modified tcp windows") show `TCP_WND` moving from 8196→2048 — the value still active today.
**Result:** The historically intended benchmark was RT-Thread's `netutils` `iperf` package (iperf2-compatible raw stream), not NetIO, not lwIP's own `lwiperf`.
**Consequence:** NetIO was removed; netutils iperf (package commit `b77ba3f80f7ab48f7ec22685d495daa7bbffeb44`) was cloned into `packages/netutils-latest/` and wired in via a hand-written `packages/SConscript` aggregator (the standard RT-Thread env-tool boilerplate that manual cloning doesn't auto-generate).
**Current status:** VERIFIED (current benchmark, confirmed present in the tree at archival time).

---

## Event 4 — Original traffic-direction assumption and its correction
**Prior belief (implicit, early testing):** either direction was exercised experimentally without a fixed rule — the earliest live tests included Ubuntu→RT-Thread (RT-Thread as `iperf -s`) as well as RT-Thread→Ubuntu (RT-Thread as `iperf -c`), both validated as working.
**Evidence:** source audit of `iperf.c` (both `iperf_client()`/`iperf_server()` functions exist; the tool supports either role) plus the netem-direction analysis: `tap0`'s root `netem` qdisc only delays host **egress**. For Ubuntu→RT-Thread runs, DATA is delayed; for RT-Thread→Ubuntu runs, only the returning ACKs are delayed and DATA is not.
**Result:** Because `TCP_SND_BUF`/`TCP_SND_QUEUELEN`/`MEMP_NUM_TCP_SEG` are **sender-side** resources, only a sender-side experiment (RT-Thread as sender) isolates their effect cleanly.
**Consequence:** The formal design was fixed to **RT-Thread → Ubuntu only**; Ubuntu→RT-Thread runs were explicitly excluded from the Phase 1 dataset, even though both directions were shown to work mechanically.
**Current status:** VERIFIED (direction rule) — recorded in `bsp/qemu-vexpress-a9/experiment/manifest.yaml`.

---

## Event 5 — Early throughput observations (pre-instrumentation, pre-netem and post-netem)
**Prior belief:** none — first real transfer tests.
**Evidence:** live console/tmux output during netutils-iperf validation testing.
**Result (SESSION-DERIVED — NOT YET ARCHIVED, no saved log):**
- Before `netem` was applied (clean QEMU virtual link): RT-Thread-as-server received at ~8.9–17.6 Mbps per 5 s interval; RT-Thread-as-client sent at ~13.3–26.1 Mbps per interval. Host-side (authoritative) `iperf` finals for that same session: Ubuntu→RT-Thread 41.2 MB/30.08 s ≈ 11.5 Mbit/s; RT-Thread→Ubuntu 74.8 MB/32.51 s ≈ 19.3 Mbit/s.
- After `netem delay 50ms` was applied and the instrumentation build was tested (baseline `TCP_SND_BUF=8196`): RT-Thread self-reported ≈1.24–1.25 Mbps per 5 s interval, repeatedly, across at least three separate test runs in this session.
**Consequence:** Confirms the expected qualitative effect of adding a fixed one-sided delay to a small-window connection (large drop from ~19 Mbps to ~1.25 Mbps), consistent with a window/BDP-limited regime, but **no formal measurement protocol (5 reps, qdisc validity checks, recorded run IDs) was applied to any of these numbers.**
**Current status:** PILOT ONLY — see `04_historical_measurements.md` for the full table and eligibility classification.

---

## Event 6 — Changes between `TCP_SND_BUF=8196` and `16384`
**Prior belief:** unknown whether 16384 was a safe, buildable value.
**Evidence:** compile-time constraint arithmetic (`02_experiment_history.md` Event 8) plus an actual build: `TCP_SND_BUF=16384`, `TCP_SND_QUEUELEN=22`, `MEMP_NUM_TCP_SEG=40` — this is exactly the boundary case where `min_queue = 2*(16384//1460) = 22`, equal to the current `TCP_SND_QUEUELEN`.
**Result:** Build **passed** at exactly this boundary (`22 >= 22`). Macro dump confirmed `TCP_SND_BUF=16384` with `TCP_SND_QUEUELEN`/`MEMP_NUM_TCP_SEG` unchanged.
**Consequence:** `16384` was accepted as a ladder point; no throughput data exists yet at this configuration (build-only).
**Current status:** VERIFIED (build-time). **Label superseded:** this point is now **`L1`**, and it is built at the pinned `QUEUELEN/SEG = 44/44`, not at `22/40` — see `raw_logs/build_L1.log`. The `22/40` build recorded in this event remains historically valid but is not a Phase 1 configuration. Still TO VERIFY: no runtime throughput data exists at any ladder point.

---

## Event 7 — Source audit of sender-side PCB fields
**Prior belief:** assumed conventional field names (e.g. `snd_una`) would exist, matching common TCP-stack terminology.
**Evidence:** direct read of `lwip-2.0.3/src/include/lwip/tcp.h`.
**Result:** `snd_una` **does not exist** in this struct; the closest functional equivalent is `lastack` (`tcp.h:257`). `cwnd` is proven (from the update code, not the name) to be denominated in bytes. `snd_buf`/`cwnd`/`snd_wnd` are all `tcpwnd_size_t`, which resolves to `u16_t` in this build because `LWIP_WND_SCALE=0`.
**Consequence:** Any thesis text referencing "`snd_una`" is wrong for this codebase and must say `lastack`.
**Current status:** VERIFIED.

---

## Event 8 — Discovery of the 16-bit `TCP_SND_BUF` boundary
**Prior belief:** assumed larger `TCP_SND_BUF` values were safe as long as the documented lwIP sanity-check formula (`TCP_SND_QUEUELEN >= 2*SND_BUF/MSS`) was satisfied.
**Evidence:** Full transcription of every `#error`-gated compile-time check in `init.c` (both the always-on checks at `init.c:154-163` and the `LWIP_DISABLE_TCP_SANITY_CHECKS`-gated block at `init.c:298-328`). Found that `TCP_WND` and `TCP_SND_QUEUELEN` each have an **unconditional** "must fit in u16_t" check, but **`TCP_SND_BUF` does not** — confirmed by grep, zero matches for an equivalent check.
**Result:** `TCP_SND_BUF` can be configured above 65535 and still compile, because nothing checks it against the type width of the field it is ultimately assigned into (`pcb->snd_buf`, `tcp.c:1608`).
**Consequence:** Directly motivated the `TCP_SND_BUF=65536` build test (Event 9).
**Current status:** VERIFIED.

---

## Event 9 — 65536 build test and compiler warning
**Prior belief:** none — first empirical test of the boundary found in Event 8.
**Evidence:** `TCP_SND_BUF` set to 65536 (with `TCP_SND_QUEUELEN`/`MEMP_NUM_TCP_SEG` raised to satisfy the *other*, still-active constraints — `88`/`88`, from the `2*(65536//1460)=88` formula), built twice in this session (once during the parameter-matrix validation task, once again live in direct response to the user asking to "check rtt source code" for a `TCP_SND_BUF` limitation).
**Result:** Build **succeeds** (no `#error`). GCC emits an unsigned-conversion overflow warning at the point `TCP_SND_BUF` is assigned into `pcb->snd_buf` (`tcp.c:1608`), stating the value changes from `65536` to `0`.
**Consequence:** `65536` is excluded from the accepted ladder — it is a configuration that compiles but is proven (by the compiler itself) to silently misconfigure at runtime. Tree was reverted to baseline (`8196`/`22`/`40`) immediately both times.
**Current status:** VERIFIED (mechanism, build success) / `SESSION-DERIVED — NOT YET ARCHIVED` for the exact warning text (never redirected to a saved log — see `01_verified_facts.md` F33). **Whether the runtime `snd_buf=0` truncation has actually been *observed* at runtime (vs. only following from the compiler diagnostic and the type chain) — it has NOT been observed at runtime.** No firmware was ever booted with `TCP_SND_BUF=65536`; only the build step was exercised.

---

## Event 10 — Derivation of the `TCP_SND_BUF` ladder ("L0/L1/L2")
**Prior belief:** n/a.
**Note on terminology — RESOLVED.** When this event was written, the archive contained only the labels `BASE` (8196) and `B1` (16384), and it flagged "L0/L1/L2" as an unconfirmable mapping. That is now settled: **L0/L1/L2 are the adopted labels**, and the ladder has three points, not two. The mapping is `L0` = 8196 (was `BASE`), `L1` = 16384 (was `B1`), `L2` = 32768 (was `B2_rejected`). All three are built at the pinned `QUEUELEN/SEG = 44/44`.

What the historical record established at the time, and what changed:
- **8196** — the shipped baseline. Now `L0`, rebuilt at 44/44.
- **16384** — accepted upper point (Event 6), exact boundary of the `TCP_SND_QUEUELEN=22`-fixed constraint. Now `L1`, rebuilt at 44/44 where it is no longer a boundary case.
- **32768** — was build-tested as `B2_rejected` (`min_queue=44 > 22`) and confirmed to fail with the `#error` at `init.c:307`. **That rejection is superseded.** The failure was caused by holding `TCP_SND_QUEUELEN` at 22, not by the value. At the pinned 44/44 it builds cleanly and is ladder point **`L2`** (`raw_logs/build_L2.log`, `raw_logs/macro_dump_L2.txt`).
- **65536** — still excluded per Event 9 (compiles, but proven wrong at runtime by type width, not by a build failure).
- **17519** — was the arithmetic maximum with `TCP_SND_QUEUELEN=22` fixed. **Superseded and explicitly not a ladder point**: pinning at 44 raises the reachable range to the `u16_t` ceiling, and a 17519-vs-16384 step is ~7% and carries no information. Recorded in `experiment/manifest.yaml` `rejected_points` with that reason.

**Current status:** VERIFIED. Three-point ladder, all points built and archived. The "L0/L1/L2 vs BASE/B1" question is closed.

---

## Event 11 — Built-in statistics availability
**Evidence:** preprocessor dump showed `LWIP_STATS=0`, `MEMP_STATS=0`, `TCP_STATS=0`.
**Result:** lwIP's own statistics subsystem (`struct stats_`, global `lwip_stats`) is compiled with the `tcp`/`memp` members entirely absent (wrapped in `#if TCP_STATS`/`#if MEMP_STATS`).
**Consequence:** No built-in instrumentation exists; any per-connection observability requires custom instrumentation — directly motivated Events 12-16.
**Current status:** VERIFIED.

---

## Event 12 — Instrumentation design (boot banner, PCB access, sampler, accumulators, msh commands)
**Result:** designed and implemented in `applications/instr.c`/`.h` (new files) plus a minimal `lwip_get_tcp_pcb()` accessor added to `sockets.c`/`sockets.h`. Full design detailed in `01_verified_facts.md` F25-F30.
**Current status:** VERIFIED (built, linked, zero warnings).

---

## Event 13 — PCB-access implementation: first attempt failed
**Prior belief:** assumed a 2-level translation (app fd → SAL socket → lwIP fd) would suffice, based on `sal_socket.c`'s own internal `user_data` pattern.
**Evidence:** first live test: `instr_attach_client_socket(sock)` printed `"instr: could not resolve fd 4 to a tcp_pcb, sampler not armed"`.
**Result:** Tracing `sal_socket.c:1532` (`int socket = (int)(size_t)file->vnode->data;`) revealed a **3rd** level — the app-facing fd is a DFS/VFS-level fd, not the SAL index directly; `fd_get()` must resolve it to a `struct dfs_file` first.
**Consequence:** `instr_pcb_from_fd()` was corrected to the full 3-level chain (`01_verified_facts.md` F26). Second attempt succeeded silently (no error message, `"instr: sampler armed on fd=4"` printed).
**Current status:** VERIFIED (fix confirmed working in the final verification run).

---

## Event 14 — First `tcp_poll` sampler attempt: naive design rejected before running
**Prior belief:** assumed calling `tcp_poll(pcb, my_callback, interval)` directly would be a safe way to install a sampler.
**Evidence:** source read of `tcp_poll()` (`tcp.c:1793-1802`, single-slot `pcb->poll = poll;`) and `setup_tcp()` (`api_msg.c:456-465`, already installs `poll_tcp` there for ERR_MEM write-retry and close-wait logic).
**Result:** A direct `tcp_poll()` call would silently replace lwIP's own callback, degrading its write-retry mechanism — a real data-path change.
**Consequence:** Design changed to a **chaining** approach: save `pcb->poll`/`pcb->pollinterval`, install the sampler, call the saved original after sampling; restore both before close. Implemented before any code was ever run against a live pcb.
**Current status:** VERIFIED (design decision made and implemented pre-emptively, not discovered via a failed run).

---

## Event 15 — Discovery that ACK processing resets `polltmr`
**Prior belief:** assumed the poll callback would fire roughly every `pollinterval × TCP_SLOW_INTERVAL` = 2×500ms = 1000ms during the transfer.
**Evidence:** first live armed test produced `sample_count=0` after ~15-20 s of transfer. A temporary diagnostic print was added directly inside `instr_poll_cb` (confirmed it was truly never called) and then inside lwIP's own `tcp_slowtmr()` loop (`tcp.c`, temporarily, fully reverted afterward — `git diff` on `tcp.c` is empty). The temporary trace showed `polltmr` pinned at `1` every ~500ms tick, never reaching `pollinterval=2`. Grepping every write site for `polltmr` found `tcp_in.c:1203: pcb->polltmr = 0;` inside `tcp_receive()`'s "made forward progress" handling.
**Result:** `polltmr` resets to zero on every processed ACK. A continuously-ACKed bulk transfer essentially never lets it accumulate to the threshold.
**Consequence:** `tcp_poll` is confirmed to be an **idle-connection** callback by lwIP design, not a periodic sampler suitable for capturing in-transfer dynamics.
**Current status:** VERIFIED — this is the most important methodological finding of the instrumentation-build session.

---

## Event 16 — 30-second `sample_count=0` validation (formal confirmation of Event 15)
**Evidence:** full, clean verification run: `instr_reset final02` → `iperf -c 192.168.10.1 -p 5001` → 30 s wait (5 × 5s "Mbps" reports observed, ≈1.24-1.25 Mbps range) → `iperf --stop` → `instr_dump`.
**Result (verbatim, captured in conversation, also representative sample saved at `docs/tfg_evidence/raw_logs/host_iperf_server_instr_verify.log` for the host-side server log of an equivalent run):**
```
{"run_id":"final02", ... ,"sample_count":0, "snd_buf_min":0, ... }
```
**Consequence:** Confirms Event 15 empirically under the exact intended experimental condition (`netem 50ms`, baseline TCP config, RT-Thread→Ubuntu). Bounds-plausibility checks (`snd_queuelen_max <= TCP_SND_QUEUELEN`, `inflight <= snd_wnd`) are **not evaluable** from this run — there is no sampled data.
**Current status:** VERIFIED.

---

## Event 17 — Rejection of `tcp_poll` as the active-transfer sampling clock
**Result:** Formal conclusion, stated directly in the instrumentation task's own final report: `tcp_poll` cannot serve as the periodic sampler for Phase 1's in-transfer measurements.
**Consequence:** The currently-shipped sampler infrastructure (accumulators, chaining safety, fd-resolution) is correct and reusable, but its **trigger** needs to change.
**Current status:** VERIFIED as a finding; the replacement design is Event 18.

---

## Event 18 — Planned transition to a periodic sampler (NOT YET DESIGNED)
**Status: TO VERIFY / explicitly not done.** No periodic (timer-driven, ACK-independent) sampler has been designed or implemented in this session. This is recorded here only because the prior event's conclusion makes it the obvious next step — it is **not** a completed design and must not be presented as one. Candidate mechanisms (e.g., a dedicated RT-Thread software timer independent of `tcp_poll`, or hooking `tcp_sent`/`tcp_output` instead) were not evaluated against the "no data-path modification" constraint in this session.
**Current status:** TO VERIFY — this is the next concrete task (see `HANDOFF.md`).
