#!/usr/bin/env python3
"""
Mechanism-fraction (mech_app_limited / mech_unsent_pending / mech_ack_pending)
variance evidence, for a possible future `repetitions` decision. Read-only,
offline, no new measurement, no threshold/validity decision.

Step 1 -- confirm, don't assume, where mech_* is populated:
  grep every *instr_dumps*.jsonl and every b1_capture/*.json for a non-null
  mech_app_limited.

Step 2 -- confirm the three counters are mutually exclusive and exhaustive:
  mech_app_limited + mech_unsent_pending + mech_ack_pending == sample_count,
  checked on every real record found in step 1 (not just 3, the task's
  minimum).

Step 3 -- the five cells:
  - p0b_g6_instr_dumps.jsonl, pooling c1+c2 (3 runs each) into n=6 per cell,
    for (STOCK,50ms), (STOCK,500ms), (PINNED,50ms), (PINNED,500ms). Pooling
    is justified only if cfg+sampler match exactly between c1 and c2 for
    the same cell -- checked here, not assumed, and matches how 12's own
    G6 section already pools c1+c2 into n=6 ("4 builds, 24 runs, n=6 per
    (config, RTT)", 12_phase0_measurements.md around the Claim 1-3 tables).
  - b1_capture/b1_idle_1..5.json, n=5, ONE cell (natural/undisturbed,
    8196/200ms/100ms-interval/tier2). b1_load_* is NOT pooled into this --
    reported separately, labelled intervention-contaminated.

Per run (never pooling samples across runs): report each of the three
fractions as %% of that run's own sample_count. Per cell: mean, between-run
stdev (percentage points), min-max range.

Then state explicitly what coverage is MISSING at L1/L2 and at
sampling_interval_ms=20.

No repetitions recommendation, no validity policy, no root cause. Evidence
only.
"""
import sys, os, json, glob, statistics, collections

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
EVID = os.path.join(REPO, "docs", "tfg_evidence")
RAW = os.path.join(EVID, "raw_logs")


def load_jsonl(path):
    out = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        out.append(json.loads(line))
    return out


def step1_scan():
    print("=" * 78)
    print("STEP 1 -- where is mech_app_limited actually populated? (scan, not assumed)")
    print("=" * 78)
    candidates = sorted(glob.glob(os.path.join(RAW, "*instr_dumps*.jsonl"))) + \
                 sorted(glob.glob(os.path.join(RAW, "b1_capture", "*.json")))
    hits = {}
    for f in candidates:
        try:
            if f.endswith(".jsonl"):
                recs = load_jsonl(f)
            else:
                recs = [json.load(open(f))]
        except Exception as e:
            print("  %-70s UNREADABLE (%s)" % (f, e))
            continue
        n_with = sum(1 for r in recs if r.get("mech_app_limited") is not None)
        hits[f] = (n_with, len(recs))
        print("  %-70s %d / %d records have non-null mech_app_limited"
              % (os.path.relpath(f, RAW), n_with, len(recs)))
    return hits


def step2_exhaustive(hits):
    print("\n" + "=" * 78)
    print("STEP 2 -- mech_* mutual exclusivity/exhaustiveness check "
          "(mech_app_limited + mech_unsent_pending + mech_ack_pending == sample_count)")
    print("=" * 78)
    total_checked = 0
    total_bad = 0
    for f, (n_with, n_total) in hits.items():
        if n_with == 0:
            continue
        recs = load_jsonl(f) if f.endswith(".jsonl") else [json.load(open(f))]
        bad = []
        for r in recs:
            if r.get("mech_app_limited") is None:
                continue
            s = r["mech_app_limited"] + r["mech_unsent_pending"] + r["mech_ack_pending"]
            total_checked += 1
            if s != r["sample_count"]:
                bad.append((r["run_id"], s, r["sample_count"]))
        if bad:
            total_bad += len(bad)
            print("  %s: %d MISMATCHES: %s" % (os.path.relpath(f, RAW), len(bad), bad))
        else:
            print("  %s: all %d checked records sum exactly to sample_count" % (os.path.relpath(f, RAW), n_with))
    print("TOTAL checked=%d  mismatches=%d" % (total_checked, total_bad))
    if total_bad:
        print("WARNING: mech_* is NOT exhaustive/exclusive in at least one record -- "
              "do not treat fractions as a clean partition until resolved.")
    return total_bad == 0


def pct_table(cell_name, runs, n_declared=None):
    """runs: list of dict(run_id=..., sample_count=..., mal=.., mup=.., mack=..)"""
    print("\n--- cell: %s  (n=%d%s) ---" % (cell_name, len(runs),
          "" if n_declared is None or n_declared == len(runs) else
          " -- MISMATCH vs declared n=%d" % n_declared))
    print("  %-26s %10s %12s %14s %12s" % ("run_id", "sample_count", "app_limited%",
          "unsent_pend%", "ack_pend%"))
    fracs = collections.defaultdict(list)
    for r in runs:
        sc = r["sample_count"]
        pmal = 100.0 * r["mal"] / sc
        pmup = 100.0 * r["mup"] / sc
        pmack = 100.0 * r["mack"] / sc
        fracs["mal"].append(pmal)
        fracs["mup"].append(pmup)
        fracs["mack"].append(pmack)
        print("  %-26s %10d %12.3f %14.3f %12.3f" % (r["run_id"], sc, pmal, pmup, pmack))
    scs = [r["sample_count"] for r in runs]
    if max(scs) - min(scs) > 0.2 * statistics.mean(scs):
        print("  FLAG: sample_count varies by more than 20%% across runs in this cell: %s" % scs)
    else:
        print("  sample_count range in this cell: %s (not drastically different)" % scs)
    print("  %-26s %10s %12s %14s %12s" % ("", "", "mean", "stdev(pp)", "min-max"))
    for key, label in (("mal", "app_limited%"), ("mup", "unsent_pend%"), ("mack", "ack_pend%")):
        vals = fracs[key]
        mean = statistics.mean(vals)
        sd = statistics.stdev(vals) if len(vals) > 1 else float("nan")
        print("  %-26s %10s %12.3f %14.3f %12s" % ("", label, mean, sd,
              "%.3f-%.3f" % (min(vals), max(vals))))
    return fracs


def main():
    hits = step1_scan()
    ok = step2_exhaustive(hits)

    print("\n" + "=" * 78)
    print("STEP 3 -- G6 cfg/sampler match check across c1/c2 (pooling justification)")
    print("=" * 78)
    g6 = {r["run_id"]: r for r in load_jsonl(os.path.join(RAW, "p0b_g6_instr_dumps.jsonl"))}
    cells = ["STOCK_r50", "STOCK_r500", "PINNED_r50", "PINNED_r500"]
    pooled_cells = {}
    for cell in cells:
        c1_ids = sorted(k for k in g6 if ("c1_%s_" % cell) in k)
        c2_ids = sorted(k for k in g6 if ("c2_%s_" % cell) in k)
        f1, f2 = g6[c1_ids[0]], g6[c2_ids[0]]
        match = (f1["cfg"] == f2["cfg"]) and (f1["sampler"] == f2["sampler"])
        print("  %-14s c1=%s c2=%s  cfg+sampler match across c1/c2: %s"
              % (cell, c1_ids, c2_ids, match))
        if not match:
            print("    REFUSING TO POOL -- cfg/sampler mismatch (c1=%s sampler=%s vs c2=%s sampler=%s)"
                  % (f1["cfg"], f1["sampler"], f2["cfg"], f2["sampler"]))
            continue
        pooled_cells[cell] = c1_ids + c2_ids
    print("\nPrecedent cited: docs/tfg_evidence/12_phase0_measurements.md states "
          "\"4 builds, 24 runs, n=6 per (config, RTT)\" and reports G6's STOCK/PINNED "
          "x 50/500ms claims at n=6 -- this script's c1+c2 pooling matches that, it is "
          "not a new pooling scheme.")

    print("\n" + "=" * 78)
    print("PART B -- mechanism-fraction cells (each RUN is one data point; never pooling "
          "samples across runs)")
    print("=" * 78)

    for cell in cells:
        ids = pooled_cells.get(cell)
        if not ids:
            print("\n--- cell: %s -- SKIPPED (pooling refused above) ---" % cell)
            continue
        runs = []
        for rid in ids:
            r = g6[rid]
            runs.append(dict(run_id=rid, sample_count=r["sample_count"],
                              mal=r["mech_app_limited"], mup=r["mech_unsent_pending"],
                              mack=r["mech_ack_pending"]))
        pct_table("G6 %s (STOCK/PINNED x RTT, pooled c1+c2)" % cell, runs, n_declared=6)

    # B1 IDLE cell (natural/undisturbed), n=5
    idle_runs = []
    for i in range(1, 6):
        p = os.path.join(RAW, "b1_capture", "b1_idle_%d.json" % i)
        r = json.load(open(p))
        idle_runs.append(dict(run_id=r["run_id"], sample_count=r["sample_count"],
                               mal=r["mech_app_limited"], mup=r["mech_unsent_pending"],
                               mack=r["mech_ack_pending"]))
    pct_table("B1 IDLE (natural/undisturbed, TCP_SND_BUF=8196, RTT=200ms, interval_ms=100, tier=2)",
               idle_runs, n_declared=5)

    print("\n--- B1 LOAD (intervention-contaminated -- reported separately, NOT pooled as "
          "additional replicates of ordinary operating conditions) ---")
    load_runs = []
    for i in range(1, 6):
        p = os.path.join(RAW, "b1_capture", "b1_load_%d.json" % i)
        r = json.load(open(p))
        load_runs.append(dict(run_id=r["run_id"], sample_count=r["sample_count"],
                               mal=r["mech_app_limited"], mup=r["mech_unsent_pending"],
                               mack=r["mech_ack_pending"]))
    print("  %-26s %10s %12s %14s %12s" % ("run_id", "sample_count", "app_limited%",
          "unsent_pend%", "ack_pend%"))
    for r in load_runs:
        sc = r["sample_count"]
        print("  %-26s %10d %12.3f %14.3f %12.3f" % (r["run_id"], sc,
              100.0 * r["mal"] / sc, 100.0 * r["mup"] / sc, 100.0 * r["mack"] / sc))
    print("  NOT included in any mean/stdev/range above. sample_count itself collapses "
          "with the outage (170-680, vs 915-918 for IDLE) -- a symptom of the disturbance, "
          "not an independent replicate of steady-state operation. See 11_open_problems.md B4.")

    print("\n" + "=" * 78)
    print("WHAT IS MISSING -- stated precisely, no number invented, no substitution")
    print("=" * 78)
    print("""
  mech_* (mech_app_limited / mech_unsent_pending / mech_ack_pending) exists ONLY in:
    - p0b_g6_instr_dumps.jsonl   (24 runs -> 4 cells x n=6, pooled c1+c2 as above)
    - b1_capture/b1_idle_*.json  (5 runs -> 1 cell)
    - b1_capture/b1_load_*.json  (5 runs, intervention-contaminated, reported separately)

  EVERY one of these mech_* data points is at:
    TCP_SND_BUF = 8196 (ladder point L0 ONLY)
    sampling_interval_ms = 100 (NOT the 20ms interval under consideration for Phase 1)
    tier = 2 / FULL

  Confirmed ABSENT (grep/field-checked, not assumed) in:
    - p0c_g3a_instr_dumps.jsonl   (L0, 50ms, 20s runs)
    - p0c_g3b_instr_dumps.jsonl   (L0, 50ms, 20s runs)
    - p0d_g4_L0_instr_dumps.jsonl (L0, mixed RTT, 90s/100ms and 90s/10ms-interval runs)
    - p0d_g4_L2_instr_dumps.jsonl (L2 = 32768, mixed RTT, 90s runs)

  Precisely what is missing, with no substitute computed here:
    - NO mech_* replication evidence exists at L1 (TCP_SND_BUF=16384) AT ALL -- not even
      a single run, let alone a repeated cell (consistent with 11_open_problems.md N3:
      L1 has no runtime data of any kind).
    - NO mech_* replication evidence exists at L2 (32768) -- g4_L2 captured snd_buf/cwnd/
      unsent/unacked counters but never ran with the mech_* classification wired in.
    - NO mech_* evidence exists anywhere at sampling_interval_ms=20 (the interval figuring
      in the unfrozen tbd_from_pilot proposals) -- every mech_* record in the archive is
      at interval_ms=100.
    - The B1 IDLE cell is the ONLY mech_* replication at the Phase-1-relevant RTT points
      (200ms) and it is a single cell (n=5) at a single buffer size (L0) -- there is no
      replicated mech_* cell at 50/100/500ms outside of G6's pinning-control cells, and
      G6 itself is STOCK/PINNED (22/40 and 44/44 QUEUELEN/SEG), not the L0/L1/L2 buffer
      ladder that is Phase 1's actual secondary factor.
    - Throughput CV (already estimated elsewhere, e.g. 12's G6 table) is NOT a substitute
      for mech_* variance and is not used as one here: mech_* counts how samples
      classify into three TCP-state categories, which is a different quantity from
      run-to-run throughput dispersion, and no number bridging the two is computed or
      implied by this script.
""")

    print("END OF PART B.")


if __name__ == "__main__":
    main()
