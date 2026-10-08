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

---

### 2026-10-07 — Repetitions planning objective and evidence-limited n=6 (L0 only)
Commits: (pending, this entry)
Done:
  - Per explicit instruction, recorded a prospective planning objective
    (2 pp 95% t-interval half-width, per state, per stratum; replication
    unit = independent run) and applied it to the existing mechanism-fraction
    evidence rather than Phase 0 measurements retroactively redefining it.
  - Re-ran `analyse_mechfrac_variance.py` fresh (not reused from an
    earlier summary) and independently confirmed each stratum's window
    length from its own `sample_span_ticks` (G6: 21.8 s; B1 idle: 91.4 s)
    before using either number.
  - Identified 3 compatible, non-pooled strata (L0/50/200/500 ms, all at
    `interval_ms=100`), confirmed none of their 16 included runs needed a
    population-definition judgment call (all already `VALID` under every
    existing gate; B1 LOAD excluded as the deliberate intervention it is).
  - Computed `h(n) = t_(0.975,n-1) * s/sqrt(n)` per stratum for
    `mech_app_limited`, found the smallest `n` meeting 2 pp at each
    (6 / 3 / 2 for 50/200/500 ms respectively), and reported the largest
    (6) as the candidate, per instruction, rather than averaging or
    picking a convenient one.
  - Explicitly could not compute anything for `mech_unsent_pending` at any
    stratum — exactly 0 at 50 ms (structural, not noise) and
    discreteness-dominated at 200/500 ms — flagged rather than forced.
  - Specified one bounded supplementary pilot (L2/50 ms/20 ms-interval/
    60 s-duration, fixed n=6) addressing the single largest gap (zero
    `mech_*` evidence outside L0/100 ms anywhere) — recorded, not run.
  - Declined to request an Opus audit: this task does not freeze anything
    and is a fully transparent, self-checkable arithmetic calculation, not
    a protocol freeze/attribution/mechanism/contradictory-evidence
    decision under `CLAUDE.md`'s own trigger list. Self-verified instead
    (re-derived every t-value, re-ran the source script, re-checked window
    lengths independently).
Found (not sought): nothing new; this task worked entirely from already-
  verified evidence.
Failed / blocked: none.
Decisions taken:
  - Did not average or cherry-pick across the three strata's minimal-n
    values; reported the largest (6) as instructed, with the others shown
    in the same table so the per-stratum spread stays visible.
  - Did not extrapolate the L0 candidate to L1, L2, RTT=100 ms, or
    `sampling_interval_ms=20` — stated each as untested rather than
    reasoning toward a number for any of them.
  - Did not execute the proposed supplementary pilot.
  - Updated the `12` freeze-candidates table's `repetitions` row to point
    at the new section rather than duplicating the derivation there.
Still unknown after this session:
  - Whether L2's mechanism-fraction variability resembles L0's (the
    reason the proposed pilot targets L2 specifically). Whether `n=6`
    would hold up under a genuinely independent replication (this
    calculation substitutes a pilot SD and cannot guarantee that).
    Everything else already open in `11`/`12`.

---

### 2026-10-07 — Supplementary pilot authorized; BLOCKED at preflight (tap0 missing)
Commits: (pending, this entry)
Done:
  - Per explicit user authorization, planned and committed a 24-attempt
    supplementary pilot (`13_pilot_20ms.md`) addressing N18: L0/L1/L2 at
    50 ms plus L2 at 500 ms, 60 s/3 s-discard/20 ms-interval, fixed
    schedule, run IDs and L2 RTT randomization (seed 20261007) recorded
    before any measurement, committed separately (`f76c09f`) so the
    schedule's existence pre-dates any outcome.
  - Delegated preflight + attempt 1 only to `experiment-engineer`, with
    an explicit instruction to stop after one attempt for coordinator
    review before authorizing the remaining 23 — per the task's own
    "verify raw artifacts before continuing" requirement.
  - Independently verified the resulting blocker myself before accepting
    it: confirmed `tap0` does not exist; confirmed `sudo -n -l` shows only
    `tfg-set-netem` as passwordless; confirmed `tfg-set-netem`'s own
    source only operates on an *existing* tap0 (cannot create one);
    confirmed `sudo -n ip tuntap add ...` fails requiring a password.
  - Reviewed the one incidental file change (`raw_logs/build_L0.log`,
    regenerated by the mandated `set_config.sh L0` preflight-verification
    step): `.bss` grew from 130732 to 245420 bytes against an unchanged
    `.text`/`.data` and a scons "up to date" (no rebuild). Diagnosed as
    benign: the archived log pre-dates this project's later growth of
    `instr.c`'s accumulator/trace-ring fields (added across the
    2026-09-29/30 sessions, after `build_L0.log` was last archived) — the
    regenerated log is the accurate one for the current source; accepted
    and committed as a minor accuracy correction, not a regression.
Found (not sought):
  - The project's `tap0` setup has never been a tracked, reproducible
    step — shell history (read-only, not modified) shows it was always
    brought up by hand via plain interactive `sudo ip tuntap add`/
    `ip link set up`/`ip addr add`, so it does not survive a host reboot
    and every session needing real QEMU networking must expect to
    recreate it once. This was not previously recorded as a risk anywhere
    in `11`.
Failed / blocked:
  - All 24 pilot attempts: BLOCKED at preflight, before any QEMU boot
    reached an `msh` prompt. No measurement was collected; nothing was
    fabricated or approximated in its place. This is the correct,
    demonstrated-blocker stopping condition the task itself specified —
    not a failure to execute diligently.
Decisions taken:
  - Did not attempt any workaround for the missing `tap0` (no interactive
    sudo, no alternate QEMU network backend, no privilege-escalation
    request) — creating a network interface requires `CAP_NET_ADMIN` this
    session does not have, and the one approved non-interactive mechanism
    (`tfg-set-netem`) is structurally unable to create the device, only
    modify an existing one's qdisc. Recorded as `11` B5 (blocking) rather
    than silently deferred, since it blocks the entire pilot and any
    future real measurement, not just this task.
  - Did not request a sudoers change or otherwise try to resolve this
    unilaterally — that is the user's call, flagged explicitly in the
    report back to them.
Still unknown after this session:
  - Whether the pilot's 24 attempts, once `tap0` is restored, will
    actually complete without a further infrastructure gap (the
    `tmux`/`msh` control loop itself was never exercised far enough to
    confirm it reaches a working `msh` prompt end-to-end — preflight
    stopped one step before that). Everything else already open in
    `11`/`12`/`13`.

---

### 2026-10-07 — 20 ms pilot completed: 24/24 attempts, 4 strata
Commits: (pending, this entry)
Done:
  - User resolved `11` B5 interactively (`tap0` tuntap-add/link-up/addr-add,
    across two follow-up turns since the first attempt only created the
    device without bringing it up or assigning an IP — both independently
    verified by the coordinator before resuming).
  - Resumed the pilot in four checkpointed batches, each delegated to
    `experiment-engineer`, each independently re-verified by the
    coordinator from raw artifacts before authorizing the next: L0/50 ms
    (6 attempts, one duration-overrun anomaly diagnosed and retained, two
    tooling fixes derived), L1/50 ms (6, new build, boot-banner
    cross-checked), L2/50+500 ms (12, new build, RTT-interleaved per the
    pre-recorded 2026-10-07 randomization, netem verified before every
    single attempt including repeats).
  - Independently recomputed the `[3,60)`-windowed `mech_*` fractions
    myself from the raw trace files for all 24 attempts (not reused from
    either delegate's report) before writing any stratum summary.
  - Investigated two suspicious-looking whole-run numbers rather than
    accepting them: L1's constant `mech_unsent_pending=5` in every
    attempt, and L2's apparently-confirming 2.47–2.50 % at every 500 ms
    run — both traced to connection-start bursts (first 0.08–1.5 s)
    entirely inside the 3 s discard window; both are 0.000 % once
    `[3,60)` is applied, at every one of the 4 strata.
Found (not sought):
  - A uniform `mech_unsent_pending=0.000%` null result across the whole
    pilot, including L2/500 ms specifically — the cell `12`'s own text
    expected to show it *largest*, based on an older (`07`/`08`) sweep.
    Not resolved; flagged as an open discrepancy, with a candidate
    explanation (the metric's narrower buffer-full-AND-unsent-nonzero
    definition vs. the older sweep's plain unsent-nonzero count) that was
    not itself verified against this pilot's own data.
  - At the real 20 ms/60 s settings, the pilot's own internal repetitions
    candidate (largest minimal-`n` across its 4 strata) is **3** —
    smaller than `12`'s existing `n=6` (from the 100 ms-interval archive).
    Both figures are reported side by side; neither replaces the other,
    and the within-run-sample-count explanation already flagged for the
    100 ms-vs-20 ms SD difference applies equally here, unresolved.
  - One further non-blocking anomaly: the L0 tmux/QEMU session was found
    already dead before the L1 teardown step, cause unconfirmed (no
    `dmesg` access); no data loss, not investigated further.
Failed / blocked: none, after B5's resolution.
Decisions taken:
  - Retained attempt 1 (87.89 s instead of 60 s) rather than discarding
    and re-running it — the task's own rules forbid both silent
    replacement and extra repetitions; its `[3,60)` window is fully
    contained in the captured data and was verified, not assumed, to
    match the rest of that run.
  - Checkpointed after every build block (one commit per stratum-block:
    L0, L1, L2) rather than one commit for the whole pilot or one per
    attempt — matches `manifest.yaml`'s own `block_by: build` structure
    and keeps each commit independently reviewable.
  - Did not treat the pilot's own `n=3` as supplanting `12`'s `n=6`; did
    not freeze `repetitions`, `sampling_interval_ms`, or anything else.
  - Updated `11` N18 to `PARTIALLY_RESOLVED` (not `RESOLVED`) since
    RTT=100/200 ms and L0/L1 at 500 ms remain genuinely untested — the
    plan excluded them by design, not by oversight, and that gap is
    unchanged by this pilot succeeding at what it did cover.
Still unknown after this session:
  - Why `mech_unsent_pending` never appears outside a connection-start
    burst anywhere in this pilot, including at L2/500 ms. Whether the
    100 ms-vs-20 ms SD gap (both in `12` and within this pilot's own
    comparison to it) is a real physical-variability difference or an
    artifact of within-run sample count. Whether `n=3` or `n=6` (or
    neither) should inform an eventual `repetitions` freeze. The bounded
    evidence-auditor review this task's own instructions require before
    final persistence — not yet requested as of this log entry.

---

### 2026-10-07 — Pilot audit: PASS WITH QUALIFICATION, 3 claims corrected
Commits: (pending, this entry)
Done:
  - Sent the completed 24-attempt pilot to `evidence-auditor` (Opus), per
    the task's required Section 9 review, scoped to this pilot only (not
    reopening B3/B4). Result: PASS WITH QUALIFICATION — raw measurements,
    identity/configuration, and `[3,60)` arithmetic all VERIFIED; three
    interpretive claims REJECTED.
  - Independently re-verified both load-bearing corrections myself before
    accepting them, not on the audit's word alone: (1) read
    `pilot20_L2_r500_1/4.json` directly — `unsent_nonempty_count` exactly
    equals `mech_unsent_pending` (76=76, 75=75), refuting my own
    "narrower metric" explanation for the `mech_unsent_pending` null
    result; (2) read `pilot20_L1_r50_3/4`'s raw `.host_iperf.csv` and
    `.hostmon.csv` directly — confirmed a real 1 s dip to 32% of steady
    throughput coincident with a real `qemu_exec_ms` collapse (80.3 vs. a
    steady ~236) in one, and a ~5-sample deficit with `gap_max_ticks=4`
    in the other — refuting my own "zero collapses, zero host-contention
    signatures" summary.
  - Also accepted without separate re-derivation (narrower,
    lower-stakes, and consistent with the established pattern of this
    audit's accuracy): the "structural zero" mislabel, the backwards
    buffer-direction interpretation, the σ-uncertainty sensitivity
    (n=4 at L2/50ms under a conservative SD bound), and the
    counting-noise cross-check supporting (not resolving) the
    100ms-vs-20ms SD-gap caution already on record.
Found (not sought):
  - My own two withdrawn claims were both cases of offering a plausible
    sounding explanation without first checking fields already present
    in the same JSON files being explained (`unsent_nonempty_count`) or
    the same `.hostmon.csv` already captured (`qemu_exec_ms` at the dip
    second). Worth remembering: an explanation that would resolve a
    surprising result cleanly is exactly the kind of claim to check
    against already-available data before writing down, not after.
Failed / blocked: none.
Decisions taken:
  - Formally withdrew both claims as `05_invalid_superseded_claims.md`
    rows #11–12, per project convention for a claim that turns out
    wrong, rather than silently editing it out of `13`.
  - Appended (not rewrote) corrections into `13_pilot_20ms.md` (a
    consolidated "Audit corrections" section) and `12_phase0_measurements.md`
    (three separate dated boxes, placed next to each claim they
    correct) and `11`'s N18 entry — preserving each original claim's
    text so a future reader sees both what was claimed and why it was
    wrong, not just the corrected version.
  - Relabelled `pilot20_L1_r50_3/4` as anomalous-but-compliant rather
    than clean, keeping them in the L1/50ms stratum's numeric summary
    (their `[3,60)` fractions are unaffected by the correction — only
    the surrounding "zero collapses" narrative was wrong).
Still unknown after this session:
  - Whether the host-scheduling anomalies in `pilot20_L1_r50_3/4` share
    B1/R13's platform-stall cause or are unrelated minor contention —
    not investigated (out of this task's scope). Everything else
    already open in `11`/`12`/`13`.

---

### 2026-10-08 — Protocol freeze: repetitions/duration/sampling FROZEN, discard PARTIALLY FROZEN; N8 implemented
Commits: (pending, this entry)
Done:
  - Under explicit user authorization superseding the standing no-freeze
    restriction for this bounded task, froze `repetitions=6`,
    `run_duration_s=60`, `sampling_interval_ms=20`,
    `snd_buf_low_threshold=RETIRED` in `experiment/manifest.yaml`/
    `run_matrix.csv` (`reps=6` in all 19 cells); `discard_interval_s=3`
    PARTIALLY FROZEN (fully wired for N8, not yet auto-applied to primary
    `mech_*` evidence — see below). Kept `repetitions=6` per explicit
    instruction rather than reducing it to the pilot's own smaller
    per-stratum estimates.
  - Delegated to `experiment-engineer`: (a) extended the `[3,30)/[30,60)/
    [3,60)` sensitivity check from 3 to all 24 pilot attempts; (b)
    investigated `pilot20_L0_r50_1`'s overrun from its own command log,
    not just outcome consistency; (c) checked both anomalous L1 runs'
    eligibility against the plan's completeness/identity bar,
    independent of N8; (d) implemented the N8/scientific-validity
    distinction (`VALIDITY_CLASS`: `VALID_NORMAL`/`VALID_ANOMALOUS`/
    `INVALID`) in `collect_run_meta.sh`, retaining `valid` as a
    redefined compatibility field; (e) wrote and ran test coverage.
  - Independently re-verified before accepting: the agent's `[30,60)`
    figure for `pilot20_L1_r50_3` (reproduced exactly: n=1465, 0.478%);
    the exact diff of `collect_run_meta.sh`, read line by line, not
    summarized; the median-zero classification against **real** archived
    data (`b1_capture/b1_load_4.json`), not just the agent's synthetic
    fixtures — confirmed `valid=yes`, `validity_class=VALID_ANOMALOUS`.
  - Wrote and independently verified a new committed script,
    `experiment/scripts/compute_discard_windowed_mechfrac.py`, closing
    the gap (found by audit, below) that no reproducible way existed to
    apply the frozen 3s discard to the primary sender-state evidence —
    reproduces `13`'s already-published `pilot20_L0_r50_1` figure
    (3.228%) exactly.
  - Sent the complete bundle (manifest freeze, implementation diff,
    tests, 24-attempt recheck) to `evidence-auditor` (Opus) per the
    task's required review. Result: PASS WITH QUALIFICATION.
  - **Caught and corrected three factual errors the audit found**,
    independently re-verified before correcting (not taken on the
    audit's word):
    1. My own N16 claim "all 24 attempts give a safe 3-element trailing
       bin" was wrong — checked all 24 directly from their host CSVs:
       **18 three-element, 5 two-element (all at 50ms, safe for a
       different reason — small quantization step, not tail length), 1
       with no trailing bin.** Confirmed by recomputing the exact
       percentage for one 2-element case myself (`pilot20_L2_r50_1`:
       100.12% of median, not the ~80% N16 originally warned about).
    2. The manifest's `run_duration_s` comment mixed a post-discard
       sample-count minimum with an unrelated whole-run maximum
       ("2815-3037") — corrected to the real post-discard range
       (2815-2850).
    3. `00_project_state.md` cited "RTT=50/200ms" for the pilot's
       coverage; the pilot actually covered RTT=50/500ms. Corrected.
  - Fixed the one real implementation gap the audit found: stale
    "PROPOSAL -- manifest slot stays null" comments in both
    `collect_run_meta.sh` and `interval_gate.py` for `N8_DISCARD`/
    `DEFAULT_DISCARD` (now correctly say FROZEN, tied explicitly to
    `discard_interval_s`) — and, separately, corrected my own earlier
    overclaim that N8's `bin`/`band`/`allow` were "FROZEN": they were
    never part of this task's authorized 5-value bundle and are now
    labelled "documented diagnostic settings, not frozen" instead.
Found (not sought):
  - The audit's sign-test finding: a real, small (<=0.45pp) per-stratum
    directional shift between `[3,30)` and `[30,60)` across all 24
    attempts (L0 higher in the second half 6/6; L1 lower 6/6; L2/500
    lower 5/6) — far below the 2pp objective, not a sufficiency threat,
    but means "stable sub-windows" was an overclaim; corrected to name
    the shift explicitly.
Failed / blocked: none — this is the intended, authorized outcome
  (PARTIALLY FROZEN for one of five candidates, with the exact
  unresolved item named, not a failure to decide).
Decisions taken:
  - Did not implement full automatic wiring of the discard-windowing
    script into `collect_run_meta.sh` itself this task — wrote and
    verified the standalone script, specified its required role in
    `manifest.yaml`, and named the remaining wiring as an explicit
    pre-Phase-1 implementation task rather than silently calling
    `discard_interval_s` fully frozen when it isn't yet for primary
    evidence.
  - Did not re-freeze N8's `bin`/`band`/`allow` parameters — outside the
    explicitly authorized bundle, and the task explicitly said not to
    tune detector sensitivity this task.
  - Applied `reps=6` uniformly across main/platform/pinctl in
    `run_matrix.csv` — no evidence distinguishes them, and G6 (pinctl)
    already used this count historically.
Still unknown after this session:
  - Whether `collect_run_meta.sh`'s auto-wiring of the discard-windowing
    script will surface any further surprise once implemented. Whether
    RTT=100/200ms or RTT=0/STOCK at 20ms would change any frozen value —
    explicitly untested, explicitly not claimed covered. Everything else
    already open in `11`/`12`/`13`.
