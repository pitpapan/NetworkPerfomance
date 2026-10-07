#!/usr/bin/env python3
"""
B4 timeline reconstruction (read-only, offline evidence script).

Reconstructs, for every one of B1's 10 runs (b1_idle_1..5, b1_load_1..5) plus
the one flagged natural collapse (p0d_g4_L0_host_iperf.csv connection index 4,
"g4_L0_r200_t100"):

  - the FULL per-second host timeline, including the short zero-throughput
    rows that interval_gate.py's load_connections() now attributes correctly
    (B3 fix) -- this script imports the real, fixed load_connections()
    rather than reimplementing the parsing logic;
  - outage onset/end/duration and recovery value, positioned by each row's
    own t_start field (never by the short row's 19700101000000 sentinel
    timestamp);
  - cross-reference against that run's own *.hostmon.csv (1 Hz /proc
    telemetry, real timestamps) by timestamp alignment only;
  - cross-reference against that run's own instr_dump JSON
    (sample_span_ticks / tick_per_second vs host wall-clock duration,
    reported as two separate numbers, never combined/reconciled);
  - for LOAD runs, the onset/end against the declared intervention window
    (2 spinners for 10s starting at guest t~17s, per
    docs/tfg_evidence/12_phase0_measurements.md);
  - whether the run's corrected series shows one continuous outage or
    multiple separated (fully-recovered-between) events.

This script makes NO validity/root-cause/repetitions decision. It only
emits the reconstructed timeline and cross-references for the coordinator.

Usage: python3 analyse_b4_timeline.py
(no arguments; paths are relative to the repo's docs/tfg_evidence tree,
found via this file's own location)
"""
import sys, os, csv, json, statistics, collections

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from interval_gate import load_connections  # the real, fixed B3 parser

REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
EVID = os.path.join(REPO, "docs", "tfg_evidence")
B1 = os.path.join(EVID, "raw_logs", "b1_capture")
RAW = os.path.join(EVID, "raw_logs")

NEAR_ZERO_FRAC = 0.05  # a row at or below this fraction of the run's own
                        # median is counted as part of an "outage" stretch
                        # for the purposes of this reconstruction. This is
                        # a REPORTING threshold for this script only -- it
                        # is NOT the N8 gate's band (0.80) and does not
                        # change or substitute for it.


def find_stretches(rows, frac=NEAR_ZERO_FRAC):
    """rows: sorted [(ts, t_start, bps)]. Returns (median, [stretch,...])
    where each stretch is the list of row-indices in one contiguous
    (t_start step == 1) run of rows at/below frac*median."""
    vals = [b for _, _, b in rows]
    med = statistics.median(vals)
    thresh = frac * med if med > 0 else 0
    idxs = [i for i, (_, _, b) in enumerate(rows) if b <= thresh]
    groups, cur = [], []
    for i in idxs:
        if cur and rows[i][1] - rows[cur[-1]][1] <= 1.01:
            cur.append(i)
        else:
            if cur:
                groups.append(cur)
            cur = [i]
    if cur:
        groups.append(cur)
    return med, groups


def hostmon_rows(path):
    if not os.path.exists(path):
        return []
    return list(csv.DictReader(open(path)))


def hostmon_gaps(mrows):
    """Gaps in the hostmon's OWN 1Hz sampling stream (unix ts column) --
    a gap here means the monitor process itself did not get a sample in,
    which is itself evidence, not assumed error."""
    gaps = []
    prev = None
    for r in mrows:
        u = int(r["unix"])
        if prev is not None and u - prev > 1:
            gaps.append((prev, u, u - prev))
        prev = u
    return gaps


def hostmon_window(mrows, ts_lo, ts_hi):
    """mrows with 'ts' (YYYYMMDDHHMMSS string) in [ts_lo, ts_hi] inclusive."""
    return [r for r in mrows if ts_lo <= r["ts"] <= ts_hi]


def report_run(label, rows, instr, mrows, declared_onset=None, declared_dur=None):
    med, groups = find_stretches(rows)
    print("\n--- %s ---" % label)
    print("  n_rows=%d  steady_median=%d bit/s" % (len(rows), med))
    if not groups:
        print("  no outage stretch found (>= %.0f%% of median throughout)" % (100 * NEAR_ZERO_FRAC))
    for gi, g in enumerate(groups, 1):
        t0 = rows[g[0]][1]
        t1 = rows[g[-1]][1]
        dur = t1 - t0 + 1
        recov_idx = g[-1] + 1
        recov_val = rows[recov_idx][2] if recov_idx < len(rows) else None
        onset_ts = rows[g[0]][0]
        end_ts = rows[g[-1]][0]
        print("  event %d: onset t=%g (row ts=%s)  end(last depressed row) t=%g (row ts=%s)"
              % (gi, t0, onset_ts, t1, end_ts))
        print("           duration=%ds (n=%d depressed rows)  recovery_value=%s bit/s (row after)"
              % (dur, len(g), recov_val))
    if len(groups) == 0:
        pass
    elif len(groups) == 1:
        print("  SHAPE: one continuous depressed stretch, no intervening recovery.")
    else:
        # check whether the gap between consecutive groups has values that
        # look like a genuine return to steady state, or just a brief
        # partial blip
        print("  SHAPE: %d separated depressed stretches -- values between them:" % len(groups))
        for gi in range(len(groups) - 1):
            lo = groups[gi][-1] + 1
            hi = groups[gi + 1][0]
            between = rows[lo:hi]
            vals = [b for _, _, b in between]
            if med:
                pct = ["%.0f%%" % (100.0 * v / med) for v in vals]
                print("    between event %d and %d (t=%g..%g): values=%s (%% of median=%s)"
                      % (gi + 1, gi + 2, rows[lo][1] if lo < len(rows) else None,
                         rows[hi - 1][1] if hi - 1 < len(rows) else None, vals, pct))
            else:
                print("    between event %d and %d (t=%g..%g): values=%s "
                      "(run median is 0 -- this run is >=95%% zero overall, see B4; "
                      "these are the raw bit/s values, not a %% of median)"
                      % (gi + 1, gi + 2, rows[lo][1] if lo < len(rows) else None,
                         rows[hi - 1][1] if hi - 1 < len(rows) else None, vals))

    # instr_dump cross-reference
    if instr is not None:
        span = instr["sample_span_ticks"]
        tps = instr["sampler"]["tick_per_second"]
        guest_dur = span / float(tps)
        host_dur = rows[-1][1] - rows[0][1] + 1
        print("  GUEST (instr_dump): sample_count=%d sample_span_ticks=%d tick_per_second=%d "
              "first_tick=%d last_tick=%d => implied guest duration = %.2f s"
              % (instr["sample_count"], span, tps, instr["first_sample_tick"],
                 instr["last_sample_tick"], guest_dur))
        print("  HOST (this run's own per-second series): wall-clock duration = %.1f s "
              "(t_start 0..%g)" % (host_dur, rows[-1][1]))
        print("  NOTE: these two numbers are reported separately, not reconciled. "
              "diff = %.2f s (guest - host)" % (guest_dur - host_dur))

    # hostmon cross-reference, by real timestamp only
    gaps = hostmon_gaps(mrows) if mrows else []
    if mrows:
        print("  HOSTMON: n=%d samples, first_ts=%s last_ts=%s, internal gaps in the monitor's "
              "OWN 1Hz stream=%s" % (len(mrows), mrows[0]["ts"], mrows[-1]["ts"], gaps))
        real_rows_in_groups = []
        for g in groups:
            for i in g:
                ts = rows[i][0]
                if ts != "19700101000000":
                    real_rows_in_groups.append(ts)
        if real_rows_in_groups:
            lo, hi = min(real_rows_in_groups), max(real_rows_in_groups)
            win = hostmon_window(mrows, lo, hi)
            print("  hostmon rows with REAL timestamp falling inside a depressed stretch: %d "
                  "(window %s..%s)" % (len(win), lo, hi))
            for r in win[:5]:
                print("    ts=%s steal=%s rundelay_ms=%s exec_ms=%s ctxt=%s cpu_idle=%s procs_running=%s"
                      % (r["ts"], r["cpu_steal"], r["qemu_rundelay_ms"], r["qemu_exec_ms"],
                         r["ctxt"], r["cpu_idle"], r["procs_running"]))
        else:
            print("  hostmon cross-reference: every depressed row carries the sentinel timestamp "
                  "(no real ts survives inside the stretch); alignment to hostmon by timestamp "
                  "is UNCERTAIN for the interior of this stretch -- not guessed.")
    else:
        print("  HOSTMON: no .hostmon.csv available for this run.")

    # declared intervention window cross-reference (LOAD arm only).
    # Uses the FIRST depressed row of the FIRST event as onset (the earliest
    # sign of disturbance) and the LAST depressed row of the LAST event as
    # end (the final return to steady state), i.e. the whole episode
    # end-to-end -- not just the first group reported in the SHAPE breakdown
    # above, which can be a brief 1-2s blip ahead of the main stretch.
    if declared_onset is not None and groups:
        onset = rows[groups[0][0]][1]
        end = rows[groups[-1][-1]][1]
        dur = end - onset + 1
        print("  INTERVENTION CROSS-CHECK: declared spinner window starts at guest t~%s for %ss."
              % (declared_onset, declared_dur))
        print("    observed onset (first depressed row, any event) t=%g -- %s declared t~%s"
              % (onset, "COINCIDES WITH" if abs(onset - declared_onset) <= 3 else "DOES NOT COINCIDE WITH",
                 declared_onset))
        diff = dur - declared_dur
        if abs(diff) <= 3:
            verdict = "MATCHES (~declared duration)"
        elif diff > 0:
            verdict = "DOES NOT MATCH -- outage OUTLASTS the declared %ss spinner window by %ds" % (declared_dur, diff)
        else:
            verdict = "DOES NOT MATCH -- outage ENDS %ds SOONER than the declared %ss spinner window " \
                       "(this stretch is not the whole outage -- see SHAPE above)" % (-diff, declared_dur)
        print("    observed end t=%g => outage duration %ds -- declared spinner duration is %ss; %s"
              % (end, dur, declared_dur, verdict))


def main():
    print("=" * 78)
    print("PART A -- B4 timeline reconstruction")
    print("Using the real, fixed interval_gate.load_connections() (post-B3-fix)")
    print("=" * 78)

    for arm, declared in (("idle", None), ("load", (17, 10))):
        hostcsv = os.path.join(B1, "host_%s.csv" % arm)
        warn = {}
        conns = load_connections(hostcsv, warn=warn)
        if warn.get("orphan_transfer_ids"):
            print("WARNING orphan transfer ids in host_%s.csv: %s" % (arm, warn["orphan_transfer_ids"]))
        keys = list(conns.keys())
        for i, port in enumerate(keys, 1):
            rid = "b1_%s_%d" % (arm, i)
            instr_path = os.path.join(B1, rid + ".json")
            instr = json.load(open(instr_path)) if os.path.exists(instr_path) else None
            mon_path = os.path.join(B1, rid + ".hostmon.csv")
            mrows = hostmon_rows(mon_path)
            declared_onset, declared_dur = declared if declared else (None, None)
            report_run("%s (port %s)" % (rid, port), conns[port], instr, mrows,
                        declared_onset, declared_dur)

    print("\n" + "=" * 78)
    print("PART A.7 -- natural collapse: p0d_g4_L0_host_iperf.csv connection index 4 "
          "(g4_L0_r200_t100)")
    print("=" * 78)
    hostcsv = os.path.join(RAW, "p0d_g4_L0_host_iperf.csv")
    warn = {}
    conns = load_connections(hostcsv, warn=warn)
    if warn.get("orphan_transfer_ids"):
        print("WARNING orphan transfer ids: %s" % warn["orphan_transfer_ids"])
    keys = list(conns.keys())
    idx = 4
    port = keys[idx]
    rows = conns[port]
    instr = None
    ip = os.path.join(RAW, "p0d_g4_L0_instr_dumps.jsonl")
    for line in open(ip):
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        if d["run_id"] == "g4_L0_r200_t100":
            instr = d
            break
    report_run("g4_L0_r200_t100 (host conn index %d, port %s)" % (idx, port), rows, instr, [])

    discard = 3
    first_depressed_t = None
    med, groups = find_stretches(rows)
    if groups:
        first_depressed_t = rows[groups[0][0]][1]
    print("\n  DISCARD-WINDOW OVERLAP CHECK (discard_interval_s candidate = %ds):" % discard)
    print("    first depressed row at t_start=%s" % first_depressed_t)
    print("    discard window covers t_start in [0, %d) -- i.e. rows with t_start < %d are dropped"
          % (discard, discard))
    if first_depressed_t is not None:
        if first_depressed_t < discard:
            print("    => the stall begins INSIDE the proposed discard window (t=%s < %d): "
                  "fully or partially absorbed by discarding." % (first_depressed_t, discard))
        elif first_depressed_t == discard:
            print("    => the stall begins EXACTLY at the discard boundary (t=%s == %d): "
                  "the very first KEPT interval is already depressed -- the discard window "
                  "provides NO margin before the stall." % (first_depressed_t, discard))
        else:
            print("    => the stall begins at t=%s, AFTER the %ds discard window ends -- "
                  "not absorbed by discarding at all." % (first_depressed_t, discard))

    print("\nEnd of Part A.")


if __name__ == "__main__":
    main()
