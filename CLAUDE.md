# NetworkPerfomance TFG — persistent orchestration rules

Bachelor's thesis: sender-side TCP limiting-mechanism attribution on
RT-Thread/lwIP (`bsp/qemu-vexpress-a9`), under controlled RTT. The repository
is the persistent research memory — a fresh session reconstructs state from
it, not from chat history.

## Source of truth, in order

1. `docs/tfg_evidence/08_design_rationale.md` — wins on any design conflict.
2. `docs/tfg_evidence/00_project_state.md` — current design snapshot.
3. `bsp/qemu-vexpress-a9/experiment/manifest.yaml` + `run_matrix.csv` —
   the only executable definition of the sweep. `tbd_from_pilot` fields are
   `null` until the user freezes them; null means undecided, not a default.
4. `docs/tfg_evidence/HANDOFF.md` — map, not territory.
5. `docs/tfg_evidence/10_session_log.md` (append-only, one entry per
   session, written before commit) and `11_open_problems.md` (live; items
   retire to Resolved, never deleted).
6. `docs/tfg_evidence/12_phase0_measurements.md` — Phase 0 archive.

Do not restore the superseded BASE/B1/C1/C2/D1/D2 × 4-RTT × 5-rep scheme.
Problem IDs (B1, N8, D1, ...) are stable identifiers, not configuration
labels — never bulk-replace them.

## Research question

Under controlled RTT, which sender-side mechanism(s) limit bulk TCP
throughput — send buffer under-occupied, occupied-but-unsent, or
sent-but-released-slower-than-delay-implies? Evidence is the sender's own
joint PCB state (`snd_buf`/`unsent`/`cwnd`/`snd_wnd`), not throughput
correlation. `TCP_SND_BUF` is the probe (L0/L1/L2 = 8196/16384/32768);
`TCP_SND_QUEUELEN`/`MEMP_NUM_TCP_SEG` are pinned controls (44/44), not
factors. Multiple mechanisms may coexist; inconclusive attribution is a
valid outcome.

## Model routing (requested; verify before relying on effort fields)

Installed: Claude Code 2.1.285. `claude-sonnet-5`, `claude-sonnet-4-5`, and
`claude-opus-5-5` are all confirmed selectable on this installation/account
(OBSERVED 2026-10-06 via direct `--model` invocation; `canonicalModel`
echoed back unchanged for all three). The `--effort` flag exists at the CLI
level and `effortLevel` exists as a global per-model key in
`~/.claude/settings.json`; whether per-agent `effort:` frontmatter in
`.claude/agents/*.md` is actually honored per-invocation was **NOT
VERIFIED** — treat it as a requested annotation, not a confirmed control,
until checked.

| Role | Model | Effort | File |
|---|---|---|---|
| Main coordinator | claude-sonnet-5 | high (requested) | this session, no file |
| experiment-engineer | claude-sonnet-5 | medium (requested) | `.claude/agents/experiment-engineer.md` |
| campaign-runner | claude-sonnet-4-5 | — | `.claude/agents/campaign-runner.md` |
| evidence-auditor | claude-opus-5-5 | high (requested) | `.claude/agents/evidence-auditor.md` |
| thesis-writer | claude-sonnet-5 | medium (requested) | `.claude/agents/thesis-writer.md` |

Do not upgrade any role to a newer model generation just because one
exists. campaign-runner is usable only once the Phase 1 protocol fields
above are frozen; evidence-auditor is read-only and invoked selectively
(protocol freeze, attribution-rule changes, mechanism attribution,
contradictory evidence, final Results/Discussion claims) — not for routine
mechanically-valid runs.

## Role boundaries

Only the main coordinator commits. Subagents never commit. campaign-runner
never redesigns/debugs — anomalies return control to the coordinator.
evidence-auditor never writes files. thesis-writer never invents evidence
or strengthens a claim past its recorded classification.

## Evidence and measurement-resource discipline

- Never manually alter raw measurements; keep raw/processed/analysis
  conceptually separate.
- Preserve failed runs and anomalies; an invalid run never silently becomes
  a valid replication.
- One writer at a time in this checkout. During a measurement window this
  host/QEMU/network path is reserved for that run — no concurrent builds,
  analysis, or netem changes. The host is a 2-vCPU VirtualBox VM
  (`11_open_problems.md` N11); concurrent host load reproduces spurious
  throughput collapses (B1/R13) — this is now an operational protocol
  requirement, not just a known risk.
- Change `tap0` netem delay only via `sudo -n /usr/local/sbin/tfg-set-netem
  <ms>` (0/50/100/200/500 only); verify `tc qdisc show dev tap0` after every
  change.
- `packages/netutils-latest/iperf/iperf.c` carries hand-applied,
  **gitignored** instrumentation hooks (open problem N5) with no tracked
  patch/reconstruction file as of 2026-10-06. Loss on re-clone presents as
  `instr_sample_count=0`, indistinguishable from an unrelated instrumentation
  failure. Check this file is present and unmodified-from-expected before
  trusting any `instr_dump` output.

## Git ownership

Main coordinator only, after inspecting `git status`/`git diff`/`git diff
--cached`. Never stage unrelated work. Prefer several coherent commits
(instrumentation / exp / analysis / docs) over one commit per experiment
when they are separate logical units. No post-hoc changes to validity
thresholds, transient-discard rules, repetition policy, or attribution
criteria after seeing formal data without an explicit versioned decision.

## Thesis integration

Write only from evidence the coordinator has already classified
(VERIFIED/SUPPORTED/INCONCLUSIVE/REJECTED). "No prose change justified" is
a valid outcome of a session.

## Session bookkeeping

Every session updates `docs/tfg_evidence/10_session_log.md` (append, never
rewrite past entries — supersession goes in a later entry plus
`05_invalid_superseded_claims.md`) and `11_open_problems.md`, before
committing.
