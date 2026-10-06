# 10 — Session Log

Append one entry per session, before commit. Never rewrite past entries; if
something is superseded, say so in a later entry and in `05`.

> Numbering note: this file is `10` and `11_open_problems.md` is `11`, as
> specified. The Phase 0 measurement archive that briefly occupied `10` was
> renumbered to `12_phase0_measurements.md` in the same session that created
> this file; the only inbound reference (`05` row 6) was updated. No other
> document ever cited it as `10`.

## Template

### YYYY-MM-DD — <one-line goal>
Commits: <hashes>
Done:
  - <what was completed>
Found (not sought):
  - <anything discovered incidentally — hazards, bugs, wrong
     assumptions in the archive>
Failed / blocked:
  - <what did not work, and why>
Decisions taken:
  - <design decisions, with the reasoning, not just the outcome>
Still unknown after this session:
  - <carried to 11>

---

### 2026-09-29 — Replace the `tcp_poll` sampler and de-risk it
Commits: `a1646d5`
Done:
  - Read and audited the whole evidence archive against source, build output and
    the live console left running from the prior session.
  - Replaced the `tcp_poll`-chained sampler with an RT-Thread periodic soft timer
    (`RT_TIMER_FLAG_SOFT_TIMER | RT_TIMER_FLAG_PERIODIC`), created once at
    `INIT_APP_EXPORT`. Removed the `pcb->poll` chaining entirely.
  - Safe-shutdown tests: clean `iperf --stop`, host server `SIGKILL`ed
    mid-transfer, four consecutive attach/detach cycles. All three passed with no
    crash and `stale_count` 0.
  - Validation run at L0 / 50 ms: `sample_count` 319 against 319 expected, exact.
  - Interleaved OFF/FLOOR/FULL, two cycles, reported as numbers only.
Found (not sought):
  - `08_design_rationale.md` contained **no sampler design at all**. The sampler
    had been built from a specification that existed only in a chat message,
    while `02` Event 18 simultaneously stated no periodic sampler had been
    designed. Written in properly the next session.
  - The old `instr_detach_client_socket()` re-resolved `fd`→`pcb` and **returned
    early when that failed**, leaving instrumentation installed in `pcb->poll`.
    Resolution fails exactly during abrupt teardown, i.e. when detach matters.
  - `07_reproduction_notes.md` named a stale HEAD; `05` rows 6 and 7 restated the
    very values and schemes they existed to retire.
  - The host was running `iperf3 --server`, which the netutils client cannot talk
    to, and the live QEMU was running stale `STOCK` firmware while the on-disk ELF
    was `L0`.
Failed / blocked:
  - 500 ms validation not run: `tc` required an interactive sudo password.
Decisions taken:
  - Remove `pcb->poll` chaining rather than port it. Not touching lwIP's callback
    at all is a stronger "no data-path modification" guarantee than chaining, and
    it deletes the early-return bug above.
  - Validate the saved pcb by `tcp_active_pcbs` membership **and** the
    local/remote port pair. Membership alone is insufficient because a freed
    pcb's memp block can be recycled for a different connection at the same
    address, which would silently mix another connection's state into the run.
  - Make `off` skip starting the timer entirely instead of returning early from
    the callback, so the OFF arm is a true no-instrument baseline.
  - Allow a runtime tier inside a `WALK=1` build, deviating from the
    compile-time-only spec, because rebuilding per tier puts a boot-to-boot
    confound on a small-effect perturbation question.
Still unknown after this session:
  - Timer behaviour at 500 ms; whether the pcb-recycling guard works; whether the
    FULL tier ever produces non-zero output. All carried to `11`.

---

### 2026-09-30 — Complete Phase 0 measurement; decide nothing
Commits: `ea1963c`, `43c59ad`, `5719b39` (plus the follow-up that corrected this line)
Done:
  - **G1 archive integrity.** `05` rows 6 and 7 rewritten to point at
    `manifest.yaml` / `run_matrix.csv` instead of restating values, with a
    standing rule added at the top of that table. `07`'s HEAD hash removed in
    favour of instructions for obtaining it, likewise the stale line counts and
    build-size figures. The validated sampler design written into `08`, including
    the `tcp_poll` and `tcp_sent` rejections.
  - **G2 500 ms validation.** 647/647 samples, `gap_min == gap_max == 10` ticks.
  - **G3a variance and tier perturbation**, 24 runs interleaved in one boot.
    Run-to-run variance from the unsampled arm: SD 3450 bit/s, CV 0.28 %.
  - **G3b interval sweep**, 30 runs, 10/20/50/100/500 ms. Timing exact 30/30.
  - **G4/G3c transients and `unsent`**, 90 s traced runs plus 20 s fine-interval
    companions at four RTT points at both L0 and L2.
  - **G5** mechanism-classification statistic implemented (parameter-free).
  - **G6** pinning control, STOCK vs PINNED, interleaved by build.
  - Instrumentation additions: timing self-check (`gap_min/max_ticks`), `nrtx`
    activity counters, `unacked` accounting, `snd_buf_sum`, and a per-sample
    trace ring with an `instr_trace` CSV dump.
Found (not sought):
  - **Sporadic multi-second throughput collapses**, not a startup transient, are
    the dominant per-run error source. Examples: an interval at 11 680 bit/s
    (3.6 % of steady) at L0/200 ms, and a run whose final four intervals fell to
    1038k/721k/581k/841k. Distributed through runs, with full-rate intervals
    either side. A discard window does not address these.
  - **`snd_buf_low_count` at the 1024-byte default is degenerate**: 318/319 and
    647/647, i.e. ~1.00 at every cell, because `snd_buf` sits at exactly 0
    essentially always at L0. Motivated G5.
  - **`cwnd` keeps growing long after throughput saturates** — at L0/50 ms it is
    still climbing through 31 549 at t = 1.4 s while throughput has been at its
    steady value since t = 1 s.
  - **Transient length is not independent of `TCP_SND_BUF`.** At 500 ms, L0
    reaches full rate by host interval 1 but L2 needs interval 2 (20 % → 77 % →
    100 %). This was listed as ASSUMED independent.
  - **One genuine timing mismatch**, the only one in ~120 runs: `g4_L2_r200_i10`,
    FULL tier at a 1-tick (10 ms) interval at L2, lost 9 of 2122 expected samples
    with `gap_max` 2 and `stale_count` 0. The timer skipped ticks; the target was
    always valid.
  - A steady-state rule of the form "all later intervals within ±5 %" is
    **unusable** on this platform — the late dips falsify it, so it returned no
    answer at all for two cells whose transient is under 2 s.
  - `unsent_bytes_max` is 4100 at L0 but 24 008 – 28 672 at L2, and `snd_queuelen`
    high-water rises from 10–13 to 30–31. Still far below the pinned 44.
Failed / blocked:
  - The execution tooling (Bash, and briefly Edit) became unavailable mid-session
    for several minutes with a server-side classifier error. Cost one analysis
    pass, which was redone. No data lost.
  - The first `git add` of the P0-C commit silently added nothing because a
    relative `experiment` pathspec did not exist from the repository root. Caught
    and redone; worth remembering that `git add -A a b` aborts wholesale on a bad
    pathspec.
Decisions taken:
  - Drive netem through `sudo -n /usr/local/sbin/tfg-set-netem` and verify
    `tc qdisc show dev tap0` after **every** change, because "wrong netem delay
    was active" is an enumerated validity gate — a silently unapplied delay
    produces a bad number that looks valid.
  - Use `iperf -y C` CSV on the receiver. The human format's 3 significant figures
    cannot resolve a sub-1 % perturbation question at all.
  - Judge perturbation on medians and on a physical-consistency check rather than
    on raw means. In the raw means FULL sits below FLOOR although FULL does
    strictly more work, which is impossible for a real cost and therefore proves
    the differences are noise without needing any run excluded.
  - Make G5's statistic a three-way mechanism classification
    (`mech_app_limited` / `mech_unsent_pending` / `mech_ack_pending`) rather than
    a histogram. It maps one-to-one onto the three alternatives the research
    question names, and its only comparisons are against exact zero and a null
    pointer, so it introduces no parameter. Retained the legacy 1024 threshold
    unchanged for comparability.
  - Keep the per-sample trace ring's 1024 slots described as a capacity bound on
    printable history, not an experimental parameter, since the accumulators
    always cover the whole run regardless of wrapping.
Still unknown after this session:
  - Everything in `11`, in particular the cause of the sporadic collapses, which
    is now the largest threat to the Phase 1 dataset.

---

### 2026-10-01/06 — De-risk Phase 1: B1 cause, N8 gate, B2 pipeline, N3 ladder (in progress)
Commits: `4ab87bf` (B1 capture + N8 draft, prior stage), plus this session's commits
Done so far:
  - **B1 investigated and CLASSIFIED `SUPPORTED_PLATFORM_STALL`.** Discovered the
    measurement host is itself a 2-vCPU VirtualBox VM. Added `hostmon.py`
    (1 Hz `/proc` sampler, ~1 % overhead) and ran a pre-declared 10-run budget
    (5 IDLE + 5 LOADED) at L0/200 ms. Zero collapses in 460 idle intervals;
    collapses in 5/5 loaded runs, reproducing the archived shape and magnitude
    exactly. Full write-up in `12`.
  - **N8: a defensible per-interval gate designed, tested, and documented.**
    `interval_gate.py`. Perfect separation on the only intervention-labelled data
    (B1's own arms); 1.1 % flag rate on the rest of the archive with no
    disproportionate flagging by RTT or ladder point.
Found (not sought):
  - The working hypothesis's sharpest proposed discriminator — guest timer slip
    (`gap_max` > nominal) concurrent with a collapse — does **not** hold. All 5
    loaded runs had exactly nominal `gap_max`; a clean idle run had a 1-tick slip
    with zero throughput effect. Guest timer slip and throughput collapse are
    independent; retracted rather than kept.
  - A flat per-second band for N8 is structurally wrong, not just untuned:
    throughput is quantized in integer send-window cycles per second, so an
    *undisturbed* 500 ms run legitimately takes values as low as 50–61 % of its
    own median. Any band above ~50 % would be silently stricter at low-RTT cells
    than at high-RTT ones. Fixed by binning before comparing, which removes the
    cell-dependence structurally.
  - `collect_run_meta.sh`'s field list is missing **19** scalar fields against the
    current 28-field `instr_dump` schema (not "~12" as `11` previously estimated),
    and has no timing-drift gate, no N8 integration, and no COMPLETE/resume
    semantics. Confirmed by diff before starting B2.
Decisions taken:
  - Declare the B1 capture budget (10 runs, 5+5) *before* starting, per the
    brief's stopping-condition requirement, specifically to prevent capture
    attempts from consuming the whole session if B1 did not reproduce on demand.
    It reproduced within budget.
  - Retract the timer-slip discriminator rather than quietly dropping it, because
    the brief named it as "the single sharpest discriminator available" and a
    future session re-deriving it from `g3a_6_full` alone would repeat the same
    wrong inference.
  - Choose N8's band (0.80) from a sensitivity table reported in full, with the
    quantization bound derived from clean-run structure *before* any collapse
    label was consulted — so the binning requirement is not fitted to the
    labels, only the final band value is chosen with them in view, and that
    choice is shown as a table rather than collapsed to the one number used.
Still unknown after this session (so far):
  - Whether B1's loaded-arm mechanism explains every historical collapse (no
    telemetry existed before this capture — ASSUMED for historical runs).
  - Whether anything beyond host-CPU contention contributes (VirtualBox layer,
    TAP scheduling, QEMU-internal timer/IO were not independently instrumented).
  - The unexplained second dip cluster in every loaded run (t≈39–55 s), which
    carries a different telemetry signature than the first.
  - B2 and N3, not yet started as of this entry.

---

### 2026-10-06 — Bootstrap persistent orchestration workflow (no new measurements)
Commits: (pending, this entry)
Done:
  - Reconstructed current state from the repository rather than from any
    prior conversation: HEAD `83e2c1f` on `clean-benchmark`, 7 commits ahead
    of `origin/clean-benchmark`, one pre-existing uncommitted modification
    (`experiment/scripts/collect_run_meta.sh`, +315/-71, see below).
  - Confirmed `08_design_rationale.md`, `00_project_state.md`,
    `manifest.yaml`, `run_matrix.csv` and `HANDOFF.md` agree on the current
    mechanism-attribution framing, the 19-cell matrix (12 main + 3 platform
    + 4 pinctl), and that every `tbd_from_pilot` field (`repetitions`,
    `run_duration_s`, `discard_interval_s`, `sampling_interval_ms`,
    `snd_buf_low_threshold`) is still `null`. No conflict found between
    these files; none resolved, none invented.
  - Verified model-routing capability for the requested agent roster on the
    installed Claude Code 2.1.285: `claude-sonnet-5`, `claude-sonnet-4-5`
    and `claude-opus-5-5` are all selectable (`--model <id>`, confirmed via
    `--output-format json` → `modelUsage`/`canonicalModel` echoing the
    requested id unchanged for all three). The `--effort` flag and a
    per-model `effortLevel` key in `~/.claude/settings.json` both exist as
    real mechanisms; whether per-agent `effort:` frontmatter inside
    `.claude/agents/*.md` is actually honored per-invocation was **not**
    independently verified and is recorded as such in the new `CLAUDE.md`.
  - Installed `.claude/agents/{experiment-engineer,campaign-runner,
    evidence-auditor,thesis-writer}.md` (none existed before) and a new
    root `CLAUDE.md` indexing the source-of-truth files, model routing,
    role boundaries, measurement-resource discipline, and Git/thesis rules.
    Did not touch `~/.claude/settings.json` (account-wide, out of scope).
Found (not sought):
  - `experiment/scripts/collect_run_meta.sh` has an uncommitted, syntactically
    valid (`bash -n` clean) rewrite already sitting in the working tree —
    resume-safety (`.complete` markers, `--force`), a `--host-csv`/N8
    interval-gate integration (`GATE_DRIFT_FRAC`/`GATE_GAP_FACTOR`/`N8_*`
    env-overridable PROPOSAL constants), and a `--boot-banner` compiled-config
    cross-check. This directly addresses blocking item B2 in `11`, but the
    most recent session-log entry above (2026-10-01/06) still says "B2 ...
    not yet started as of this entry." The work is real but was never
    logged, never committed, and its N8 parameters are explicitly marked
    PROPOSAL in its own header comment — it has **not** been run end to end
    (`experiment/results.csv` still does not exist) and is not claimed
    complete by this entry. Left exactly as found; not reviewed line-by-line
    and not committed, per this session's bootstrap-only scope.
  - Open problem N5 (gitignored hand-applied hooks in
    `packages/netutils-latest/iperf/iperf.c`) is still live: confirmed via
    `git check-ignore` that the file is ignored
    (`bsp/qemu-vexpress-a9/.gitignore:16`) and a repo-wide search found no
    tracked patch/diff/overlay reconstructing it. No tracked reconstruction
    mechanism exists yet.
Failed / blocked: none.
Decisions taken:
  - Did not resume, review, or commit the uncommitted `collect_run_meta.sh`
    B2 work, and did not act on N8's PROPOSAL parameters or N3 (L1 runtime
    data), N9 (trace-ring size), or any other open problem, because this
    invocation is scoped to workflow bootstrap only (no new measurements,
    instrumentation changes, or freeze decisions) and the prior session's
    work on it is incomplete and unreviewed.
  - Committed the orchestration files separately from the pending
    experimental-code change, so the experimental diff's review and the
    workflow bootstrap are not conflated in one commit.
Still unknown after this session:
  - Whether the uncommitted `collect_run_meta.sh` rewrite actually works end
    to end against a real `instr_dump`/host-CSV pair — it has never been
    run. Whether N8's proposed gate parameters (`discard=3 bin=5 band=0.80
    allow=0`) should be frozen. Everything already listed as open in `11`.
