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

---

### 2026-10-07 — B2 end-to-end review: found and fixed one blocking bug
Commits: (pending, this entry)
Done:
  - Delegated a bounded B2 review to the `experiment-engineer` agent: verify
    the uncommitted `collect_run_meta.sh` rewrite's field-schema coverage
    against `instr.c`, its `interval_gate.py`/N8 integration, its
    `--boot-banner` cross-check, and its resume/COMPLETE semantics, and do
    a real dry run against archived evidence — explicitly no new
    QEMU/iperf/netem measurement.
  - The agent found one blocking bug and verified a fix in a disposable
    scratch copy (no tracked file touched by it). Independently
    re-confirmed myself before acting: read the exact lines, reproduced the
    broken behavior with a minimal awk test, applied the one-line-pattern
    fix to the real file, then re-ran the real fixed script against the
    real archived fixtures (`raw_logs/b1_capture/b1_idle_1.json` +
    `host_idle.csv`, and `b1_load_1.json` + `host_load.csv`) in my own
    separate scratch copy — not trusting the agent's claim alone.
  - Confirmed after the fix: `b1_idle_1` with a matching `--run-id` comes
    out `valid=yes` with `sample_count=915`/`gap_max_ticks=10` correctly
    read; a deliberately mismatched `--run-id` is now correctly caught
    (previously dead code); `b1_load_1` is correctly flagged INVALID by the
    N8 gate (`per_interval_collapse`, matching the original B1 figures).
    Confirmed via `git status` that no stray data landed in the real
    `experiment/` tree from either my or the agent's testing.
Found (not sought):
  - The bug: `collect_run_meta.sh:199-200` stripped the `HEADER`/`VALUES`
    line prefix with awk's `$1=""; print substr($0,2)` idiom, which forces
    awk to rejoin `$0` with `OFS` (a space) instead of the tab the next
    line's `IFS=$'\t' read -a` depends on. Every named-field lookup
    (`sample_count`, `stale_count`, `gap_max_ticks`, `run_id`, …) silently
    returned empty, so `instr_sample_count==0` was unconditionally true:
    every run — including a perfectly clean one — would have been recorded
    INVALID with a false "sampler never fired" reason, and the bounds/
    stale/drift/run_id-mismatch gates were dead code for as long as the bug
    existed. This would have silently produced zero valid Phase 1 data
    forever without ever looking wrong at a glance (the row still gets
    written, just always INVALID).
  - Two non-blocking residuals, now `11` items N13 (no cross-check that
    `--host-conn-index` corresponds to the same repetition as
    `--instr-json` — an operator-discipline gap) and N14 (the live
    `tc`/qdisc validity path was reasoned through but not exercised against
    a real `tap0`, since QEMU was not running and none was started).
Failed / blocked: none.
Decisions taken:
  - Applied the one-line fix directly rather than routing it back through
    another delegation, because it is routine engineering judgment on
    already-authorized B2 work (not a new design/validity/attribution
    decision), and independently re-verified it myself before committing
    rather than taking the agent's scratch-copy result on faith — this is
    research-critical plumbing (it gates every future Phase 1 run), so it
    gets checked twice.
  - Committed the full `collect_run_meta.sh` change (the pre-existing B2
    rewrite plus this fix) as one unit, since the review's purpose was
    exactly to decide whether that rewrite, as a whole, is ready — it now
    is, with the fix applied.
  - Moved `11`'s B2 row to Resolved rather than leaving it Blocking, since
    its stated blocker ("never executed end to end") is now false; left
    N13/N14 as separate non-blocking items rather than folding them into
    B2's resolution note, since they are independent, trackable gaps.
Still unknown after this session:
  - Whether the live-qdisc validity path behaves correctly against a real
    `tap0` (N14) — only resolvable by an actual QEMU session. Whether N8's
    gate parameters should be frozen. Everything else already listed as
    open in `11`, including all of Phase 1's `tbd_from_pilot` fields.

---

### 2026-10-07 — Attempted Phase 1 protocol freeze: FAILED audit, do not freeze
Commits: (pending, this entry)
Done:
  - Took the recommendations in `12`'s "Proposals for the fenced
    tbd_from_pilot slots" table (repetitions=8, run_duration_s=60,
    discard_interval_s=3, sampling_interval_ms=20, retire
    snd_buf_low_threshold) plus the N8/timing-drift/retransmission gate
    parameters, and routed the freeze decision through `evidence-auditor`
    (Opus, read-only) before writing anything to `manifest.yaml` — per the
    standing workflow, "Phase 1 protocol freeze" is an explicit Opus-audit
    trigger, and a completed pilot or recommendation alone is not a freeze
    decision.
  - Audit result: **FAIL for the bundle.** Four slots supportable with
    qualification (`run_duration_s`, `discard_interval_s`,
    `sampling_interval_ms`, retiring the legacy threshold);
    `repetitions=8` INCONCLUSIVE because its precondition depends on N8;
    the N8 gate itself REJECTED as implemented.
  - **Independently reproduced the central defect myself before accepting
    it**, rather than taking the audit on faith: read `interval_gate.py`'s
    `load_connections()` and confirmed it drops any CSV row with
    `len(f) < 9`; confirmed iperf writes a zero-throughput second as
    exactly such a short row; ran `interval_gate.py check` against
    `raw_logs/p0d_g4_L0_host_iperf.csv` connection index 4 (src_port 49157,
    transfer id 5) and got `VALID`; then confirmed from the raw CSV that
    this connection's throughput jumps `196704 bps (t=2-3s)` straight to
    `11680 bps (t=10-11s)` with the 7 seconds in between existing only as
    6-field short rows the parser silently discards — a 7-second total
    stall, worse than any collapse the gate targets, invisible to it.
    Separately confirmed the trailing-bin omission
    (`range(0, len(kept)-binsec+1, binsec)` never emits a short final bin)
    by reading the loop directly. Also independently confirmed one minor
    audit finding (stale trace-ring size: `instr.c:119` already says 8192,
    not the 1024 that `11` N9 and `12` still claimed).
Found (not sought):
  - The audit also surfaced several stale/incorrect passages in `12` and
    `08` (B1 described as "unresolved" after it was classified; "not yet
    wired" after B2 wired it; a self-referential timing-drift gate
    described as proof against stalls when B1's own loaded runs show the
    guest's sample span shrinking with the outage rather than the gate
    detecting anything; an arithmetic slip in the L2/500 ms quantization
    row; unreferenced "15-25" and "roughly triples" repetition figures)
    and a candidate alternative stall detector (guest-span/host-duration
    ratio) that separated every known-disturbed run checked, including
    the three N8 misses, with a visible but narrow margin. Not adopted —
    recorded as a proposal, not a decision (see `11` B3).
Failed / blocked:
  - The freeze did not happen. This was not a failed attempt at a
    mechanical task; it is the intended outcome of the audit gate working
    as designed (Section 48: "the current hypothesis fails" / "a proposed
    mechanism is unsupported" are valid outcomes, not failures of the
    session).
Decisions taken:
  - Did not freeze any `tbd_from_pilot` field, and did not write any gate
    parameter into `manifest.yaml`, because the evidence does not support
    it yet — specifically because `repetitions=8`'s justification assumes
    collapsed runs are reliably excluded, and that assumption is now
    falsified for the specific gate that was going to do the excluding.
  - Moved B2's successor finding to a new blocking item `11` B3 rather
    than reopening B2 (B2 was specifically "the script never ran end to
    end," which is still true and resolved; B3 is "the gate the script
    wires in doesn't catch what it claims to catch," a different claim).
  - Did not adopt the guest-span/host-duration ratio detector the auditor
    found promising — that is a new validity-gate design, not a bug fix,
    and adding it is a protocol-design decision for the user/coordinator
    to make deliberately, not a by-product of fixing N8.
  - Corrected `11` N9 immediately (trivial, source-verifiable, no judgment
    call) rather than leaving a known-stale entry in a live register.
Still unknown after this session:
  - Whether fixing N8's two confirmed defects (short-row parsing,
    trailing-bin omission) is sufficient, or whether the gate needs
    further redesign once re-evaluated against the full archive including
    the previously-invisible collapses. Whether `repetitions` should
    change once N8 is fixed and the mechanism-fraction variance (never
    estimated — the auditor's point 7) is accounted for. Whether the
    guest-span/host-duration idea is worth adopting as a second detector.
    Everything else already open in `11`.

---

### 2026-10-07 — B3 fixed, audited, and hardened; B4 corrected; still no freeze
Commits: (pending, this entry)
Done:
  - Per explicit user instruction, continued B3 under the standing
    delegation contract rather than freezing or redesigning: delegated the
    full fix (short-row attribution via transfer-id map, trailing-bin
    evaluation) to `experiment-engineer`, independently reproduced the two
    before/after cases myself from raw data, then delegated a hardening
    pass (8 new synthetic regression tests, a full 105-connection
    before/after archive table, an end-to-end `collect_run_meta.sh`
    re-verification, and a recomputed B1 run 4/5 timeline) to the same
    role, then sent the whole bounded patch to `evidence-auditor` (Opus)
    per the user's explicit requirement, before touching any record.
  - Audit result: **PASS WITH QUALIFICATION.** Confirmed correct: column
    choice and attribution logic (checked against 2 real files), orphan
    handling, tail-bin arithmetic (actual length, not nominal), the 4
    exact verdict changes (reproduced by hand), collector compatibility
    (`INVALID`/`INSUFFICIENT` both reject a row). Found and required
    correcting: a stale docstring; an orphan-warning/stdout-stderr
    buffering race that could corrupt the parsed verdict under
    `collect_run_meta.sh`'s `2>&1` capture; a short-trailing-bin
    quantization risk (not present in the real archive, relevant to
    future parameter choices); an over-claimed "new finding" about
    `collect_run_meta.sh` carrying the same defect (rejected — that path
    is protected by iperf's own summary row in every real case); and
    confirmed the B4 entry's "2-4 s dip for runs 1-3" figure is wrong
    (actual: 20/35/23 s contiguous zero stretches), which also undermines
    the dilution leg of `12`'s `run_duration_s=60` reasoning.
  - Applied the two required code fixes directly (routine, well-specified,
    independently verified — not delegated): reordered the orphan warning
    after the verdict print AND added an explicit `sys.stdout.flush()`,
    because testing the ACTUAL merged `2>&1` byte stream (not just source
    line order) showed print-order alone was insufficient — Python
    block-buffers stdout but not stderr when neither is a tty, so a later
    stderr write can still win the race against an earlier, still-buffered
    stdout write. Caught this myself by testing the real merged stream
    before trusting the first fix; re-verified after the `flush()` that
    the verdict is reliably first. Fixed the stale docstring. Added a
    code comment at the B1 LOAD selftest loop explaining the two
    intentional `INSUFFICIENT`-vs-`INVALID` FAILs are tracked (B4), not a
    regression to chase.
  - Independently re-confirmed, a third time, via direct script execution
    (not the subagent's or auditor's hand computation): exactly 4 of 105
    archived connections change verdict between committed HEAD and the
    working tree, matching both prior reports exactly.
  - Corrected `11`'s B3 row, which a prior edit this session had deleted
    outright instead of moving to Resolved (the auditor caught this —
    confirmed true on inspection, fixed). Corrected B4's "2-4 s" figures.
    Updated N8 to reflect the fix instead of "carries a broken gate."
    Added N16 (short-trailing-bin risk) and N17 (the corrected, narrower
    `collect_run_meta.sh` latent risk, replacing the rejected over-claim).
    Appended a dated correction note to `12` after the proposals table
    (not rewriting the original rows) explaining the `run_duration_s`
    impact and the `discard_interval_s` caveat (`g4_L0_r200_t100`'s stall
    begins inside the 3 s discard window).
Found (not sought):
  - Same as the two prior entries' "Found" sections (B1 run 4/5
    heterogeneity, the g3a_4_floor dilution blind spot) — not repeated
    here; see B4 and N16.
Failed / blocked:
  - My first fix for the orphan-warning ordering bug (moving the `print`
    call later in source) was insufficient and I caught this myself before
    committing, by testing the actual `2>&1`-merged output rather than
    trusting source-line order. Worth remembering: stdio buffering
    behavior, not print order, determines interleaving across a pipe.
Decisions taken:
  - Did not change `selftest`'s `want="INVALID"` for B1 LOAD runs 4/5 to
    make the suite pass. The auditor offered this as one acceptable
    option; chose instead to keep the strict intervention-based label and
    document the FAIL as intentional, so the INSUFFICIENT/INVALID
    distinction (which is itself evidence, per B4) stays visible on every
    run rather than being absorbed into a passing test.
  - Did not re-tune `band`/`discard`/`bin`/`allow` to raise the 3/7
    historical-label catch rate. `g3a_4_floor` and three `g4_L0` dips are
    diluted by the `bin=5` averaging design itself, not a parsing defect;
    changing parameters now would be exactly the "retune to fit known
    examples" the user's instructions explicitly forbade.
  - Did not implement the auditor-proposed guest-span/host-duration
    detector. Still an unadopted proposal.
  - Did not freeze `repetitions`, `run_duration_s`, `discard_interval_s`,
    `sampling_interval_ms`, or any gate parameter. `12`'s correction note
    explicitly states `repetitions=8` remains unfrozen.
Still unknown after this session:
  - Whether B4 (R13/N12 implications) needs its own audit pass or further
    evidence before the next freeze attempt. Whether a corrected
    sensitivity table (post-B3-fix) would support a different `band` than
    0.80 — not computed this session, since doing so without also
    resolving B4 would freeze on an incomplete picture. Everything else
    already open in `11`, unchanged by this session except as noted above.

---

### 2026-10-07 — Freeze-readiness assessment: B4 resolved (reframed), still not freeze-ready
Commits: (pending, this entry)
Done:
  - Per explicit user instruction, completed one bounded offline
    freeze-readiness assessment: resolved B4 through existing evidence,
    established a proposed (unimplemented) scientific role for N8,
    extracted mechanism-fraction replication evidence from the existing
    archive, and reassessed all five `tbd_from_pilot` candidates
    individually.
  - Delegated the offline extraction (B1/g4 timeline reconstruction
    cross-referenced against hostmon + instr_dump, mechanism-fraction
    variance tables, existing-test run) to `experiment-engineer`, who
    wrote two new reproducible scripts
    (`analyse_b4_timeline.py`, `analyse_mechfrac_variance.py`).
    Independently re-ran both myself and reproduced the numbers exactly
    before using them, plus independently re-derived two of the most
    consequential figures by hand from raw `host_iperf`/`hostmon.csv`
    files (the discard-window overlap for `g4_L0_r200_t100`; the exact
    jiffy/ctxt counts during run 1's 22 s hostmon gap).
  - Drafted a full assessment (B4 resolution text, N8 4-way classification
    proposal, 5 freeze-candidate verdicts) and sent the complete package
    to `evidence-auditor` (Opus) before writing anything into `11`/`12`,
    per explicit instruction. Audit result: **PASS WITH QUALIFICATION** —
    the raw observations held up, but several of my own interpretations
    were wrong and required correction before persisting.
  - **Corrected my own draft before writing anything, not after**:
    independently re-verified the audit's two most consequential
    corrections myself from raw data rather than taking them on faith:
    (1) read `b1_load_1.hostmon.csv` directly and confirmed the 22 s gap's
    cumulative `/proc/stat` jiffy delta is ~15 (against an expected ~4400
    for 22 s on 2 vCPUs) and ctxt delta ~513 (against ~33000 expected) —
    this rules out my own "multi-process contention" wording (ordinary
    process-level contention would still show normal cumulative kernel
    accounting, just reattributed) and supports the audit's "the whole VM
    wasn't being scheduled" reading instead; (2) confirmed G6 PINNED's
    compiled config is literally L0 under `controls_pinned`
    (`8196/44/44`), not a separate "pinning-control-only" population as my
    own draft had wrongly characterized it — this means mechanism-fraction
    replication exists at three L0 RTT points (50/200/500 ms), not one.
  - Persisted the corrected version only: moved B4 to Resolved in `11`
    with the reframed finding ("same signature in all 5 runs, differs
    only in duration" — not "runs 4/5 are categorically different," my
    own initial framing, withdrawn); appended correction notes (not
    rewrites) to R13 and N12; updated N8's entry with the corrected policy
    proposal and the manifest-mismatch finding; appended a dated
    freeze-readiness section to `12` with the corrected mechanism-fraction
    table and all 5 candidate verdicts.
Found (not sought):
  - The audit's jiffy/ctxt-accounting finding is itself a new,
    independently-reproducible piece of evidence about B1's mechanism,
    beyond anything in the archive before this session: not "QEMU lost a
    scheduling contest," but "the measuring host's own kernel barely
    accounted for any CPU time at all during the gap," which points lower
    (VirtualBox/physical host) than R13's original framing implied.
  - My own first-draft error pattern this session: I twice reached for an
    intuitive mechanism story (host process contention; a clock-rate
    ratio) that was more dramatic-sounding and less precisely supported
    than what a careful reading of the raw counters actually shows
    (near-total absence of cumulative accounting; an additive, not
    multiplicative, guest-time gap). Worth remembering for future
    sessions: prefer the plainest reading the numbers support over the
    more narratively satisfying one.
Failed / blocked: none.
Decisions taken:
  - Did not implement the N8 classification policy, change any gate
    threshold, or touch `manifest.yaml`/`collect_run_meta.sh` — the task
    explicitly scoped this to assessment, not implementation.
  - Did not freeze `run_duration_s`, `repetitions`, or any other
    candidate. Two have a documented, specific gap (duration's rationale
    is gone; repetitions lacks a mechanism-fraction precision target and
    its exclusion precondition is unmet) rather than a patched-over
    number.
  - Resolved B4 rather than leaving it open, since the audit's own
    recommendation was to do so once the mechanism wording was corrected
    and the open mechanism-locus question was explicitly forwarded to N12
    rather than silently closed with B4.
Still unknown after this session:
  - Whether the sub-Ubuntu-kernel-layer hypothesis (VirtualBox/physical
    host) is correct — N12 remains open, now with sharper (but still not
    conclusive) evidence pointing that way. Whether/how the N8 policy
    proposal should actually be adopted, and how it would reconcile with
    `repetitions`. Everything else already open in `11`/`12`, unchanged
    except as corrected above.
