#!/usr/bin/env python3
"""
N8 -- per-interval validity gate for a Phase 0/1 run.

THE RULE (parameters are proposals, not decisions; see
docs/tfg_evidence/12_phase0_measurements.md):

  1. Drop the first D seconds of per-second host intervals (startup transient).
     The transient and later disturbances are handled by DIFFERENT mechanisms:
     the transient is excluded by D, disturbances are detected after D.
  2. Aggregate the remaining intervals into consecutive non-overlapping bins of
     B seconds (mean bps over the bin, divided by however many seconds that
     bin actually has -- the trailing bin is evaluated, not dropped, on the
     same footing as a full bin. CAVEAT, not yet resolved: a short trailing
     bin (1-2 seconds) partially reintroduces the per-second quantization
     this binning step exists to remove -- see docs/tfg_evidence/11_open_problems.md
     N16. Not observed in the archive as of 2026-10-07 (real trailing bins
     are 2-4 seconds there), but relevant to future run_duration_s/
     sampling_interval_ms choices).

     WHY BINNING IS NOT OPTIONAL. Throughput here is ~TCP_SND_BUF per RTT, so a
     1-second interval contains an INTEGER number of send-window cycles and its
     value is quantized at 1/(cycles per second). That is ~5% at L0/50ms but
     20% at the 200ms cells and 50% at the 500ms cells. Measured: an
     UNDISTURBED L0/500ms run takes only the values {81.1, 90.4, 100}% of its
     median, and an undisturbed L2/500ms run only {60.9, 100}%. So a fixed
     per-second band anywhere above ~50% flags ordinary window-boundary slip at
     high-RTT cells -- it is silently a different rule at each cell, which is
     exactly what using the run's own median was supposed to prevent.
     Binning B seconds multiplies the cycles per bin by B and divides the
     quantum by B, which removes the cell dependence structurally instead of by
     tuning a threshold per cell.
  3. Let M = median of the binned values. M is the run's OWN reference, so the
     rule is scale-free across the ~40x span of steady rates on the grid
     (131136 bit/s at L0/500ms to 4915200 at L2/50ms).
  4. Count bins with value < F * M. Call these depressed.
  5. INVALID if depressed > K.

Properties required of the gate, and why each holds:
  - deterministic and scriptable: pure function of the archived CSV.
  - outcome-independent: reads only the run's own interval series. It never
    sees the config, the treatment, the RTT, or any other run. It cannot
    prefer a convenient result because it cannot see one.
  - preserves the raw run: emits a verdict, never deletes anything.
  - uniformly available: per-second host CSV exists for every run by protocol.

Usage:
  interval_gate.py check <host.csv> <conn_index> [--discard D] [--bin B] [--band F] [--allow K]
  interval_gate.py selftest
Exit code 0 = VALID, 2 = INVALID, 1 = usable data missing.
"""
import sys, os, collections, statistics, tempfile

DEFAULT_DISCARD = 3      # s   PROPOSAL -- manifest slot stays null
DEFAULT_BIN     = 5      # s   PROPOSAL -- manifest slot stays null
DEFAULT_BAND    = 0.80   #     PROPOSAL -- manifest slot stays null
DEFAULT_ALLOW   = 0      #     PROPOSAL -- manifest slot stays null


def load_connections(path, warn=None):
    """Return OrderedDict{src_port: [(ts, t_start, bps)]} of per-second rows,
    sorted by t_start within each connection.

    iperf emits a zero-throughput second as a SHORT row (6 fields, source
    address/port blank) instead of the normal 9-field row, e.g.
    "19700101000000,,5,3.0-4.0,0,0". Positionally f[2] is the connection's
    src_port in a normal row but the TRANSFER ID in a short row (the
    src_port field is blank because iperf has nothing to report); the
    transfer id itself lives at f[5] in normal rows. We build an
    id->src_port map from the well-formed rows in this file, then attribute
    each short row's implied 0 bps sample to that connection via the map.
    A short row whose id never appears in any well-formed row in the file
    cannot be attributed to a connection; it is dropped and counted in
    `warn` (a dict passed by the caller) rather than silently discarded.
    """
    normal_rows = []   # (src_port, ts, a, bps)
    short_rows = []    # (transfer_id, ts, a)
    id_to_port = {}
    for line in open(path):
        f = line.strip().split(',')
        if len(f) >= 9:
            try:
                bps = int(f[8])
                a, b = [float(x) for x in f[6].split('-')]
            except ValueError:
                continue
            if b - a > 1.6:          # the per-connection summary row, not an interval
                continue
            id_to_port.setdefault(f[5], f[2])
            normal_rows.append((f[2], f[0], a, bps))
        elif len(f) == 6:
            try:
                a, b = [float(x) for x in f[3].split('-')]
            except ValueError:
                continue
            if b - a > 1.6:
                continue
            short_rows.append((f[2], f[0], a))
        # else: neither shape recognised -- not one of the two known row
        # formats in the real archive; skip it.

    conns = collections.OrderedDict()
    for port, ts, a, bps in normal_rows:
        conns.setdefault(port, []).append((ts, a, bps))

    orphan_ids = set()
    for tid, ts, a in short_rows:
        port = id_to_port.get(tid)
        if port is None:
            orphan_ids.add(tid)
            continue
        conns.setdefault(port, []).append((ts, a, 0))

    if orphan_ids and warn is not None:
        warn["orphan_transfer_ids"] = sorted(orphan_ids)

    for port in conns:
        conns[port].sort(key=lambda r: r[1])
    return conns


def gate(rows, discard=DEFAULT_DISCARD, band=DEFAULT_BAND, allow=DEFAULT_ALLOW,
         binsec=DEFAULT_BIN):
    """rows: [(ts, t_start, bps)]. Returns (verdict, reason, detail dict)."""
    kept = [(ts, a, b) for ts, a, b in rows if a >= discard]
    if len(kept) < 2 * binsec:
        return "INSUFFICIENT", (
            "fewer than %d intervals after the %ds discard window (need 2 bins of %ds)"
            % (2 * binsec, discard, binsec)), {}
    bins = []
    for i in range(0, len(kept), binsec):
        chunk = kept[i:i + binsec]
        bins.append((chunk[0][0], int(chunk[0][1]),
                     sum(c[2] for c in chunk) / float(len(chunk))))
    # The trailing bin (if len(kept) is not a multiple of binsec) is shorter
    # than binsec seconds and so has coarser quantization than a full bin
    # (same reasoning as the module docstring's case for binning at all),
    # but it is evaluated anyway: skipping it would blind the gate to a
    # collapse that happens to land in the last partial bin of a run.
    m = statistics.median([b for _, _, b in bins])
    if m <= 0:
        return "INSUFFICIENT", "run median is zero", {}
    depressed = [(ts, t, b, 100.0 * b / m) for ts, t, b in bins if b < band * m]
    d = dict(median=m, n_bins=len(bins), n_intervals=len(kept), depressed=depressed,
             discard=discard, band=band, allow=allow, binsec=binsec)
    if len(depressed) > allow:
        worst = min(depressed, key=lambda x: x[3])
        return "INVALID", (
            "per_interval_collapse: %d of %d %ds-bins below %.0f%% of the run median "
            "%d bit/s after the %ds discard window (allowed %d); worst bin at t=%ds "
            "= %d bit/s = %.1f%% of median; bin_start_seconds=%s"
            % (len(depressed), len(bins), binsec, 100 * band, m, discard, allow,
               worst[1], worst[2], worst[3], [x[1] for x in depressed])), d
    return "VALID", "", d


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 1
    if sys.argv[1] == "selftest":
        return selftest()
    if sys.argv[1] != "check":
        print(__doc__); return 1
    path = sys.argv[2]
    idx = int(sys.argv[3])
    kw = {}
    for flag, key in (("--discard", "discard"), ("--band", "band"),
                      ("--allow", "allow"), ("--bin", "binsec")):
        if flag in sys.argv:
            v = sys.argv[sys.argv.index(flag) + 1]
            kw[key] = int(v) if key != "band" else float(v)
    warn = {}
    conns = load_connections(path, warn=warn)
    keys = list(conns.keys())
    if idx >= len(keys):
        print("INSUFFICIENT no connection at index %d (found %d)" % (idx, len(keys)))
        return 1
    verdict, reason, d = gate(conns[keys[idx]], **kw)
    # The verdict line must be the first line of the COMBINED stdout+stderr
    # stream: collect_run_meta.sh runs this under `2>&1` and takes the first
    # token of that combined output as the verdict (`awk '{print $1; exit}'`).
    # Printing the verdict to stdout first is NOT enough on its own -- Python
    # block-buffers stdout when it isn't a tty (which it never is here) but
    # leaves stderr unbuffered, so a later stderr write can still reach the
    # pipe before an earlier, still-buffered stdout write. The explicit
    # flush() below is load-bearing, not cosmetic; without it the orphan
    # warning (file-wide, not specific to this connection) can still win the
    # race and become the parsed "verdict" instead of
    # VALID/INVALID/INSUFFICIENT. Verified against the actual `2>&1`-merged
    # byte stream, not just source-line order, before relying on this.
    print("%s %s" % (verdict, reason))
    sys.stdout.flush()
    if warn.get("orphan_transfer_ids"):
        print("WARNING: short rows with unattributable transfer id(s) %s dropped"
              % warn["orphan_transfer_ids"], file=sys.stderr)
    return {"VALID": 0, "INVALID": 2}.get(verdict, 1)


def _normal_row(ts, port, tid, a, b, by, bps):
    return "%s,192.168.10.2,%s,192.168.10.1,5001,%s,%.1f-%.1f,%d,%d" % (
        ts, port, tid, a, b, by, bps)


def _short_row(ts, tid, a, b):
    # Real iperf -y C short rows: ts,,transfer_id,interval,bytes,bps -- 6 fields,
    # source address/port blank. See load_connections() docstring.
    return "%s,,%s,%.1f-%.1f,0,0" % (ts, tid, a, b)


def selftest_b3_regressions(chk):
    """B3 regression coverage: short-row zero-throughput attribution (the
    id->src_port map) and the trailing partial bin. Each case is run through
    load_connections() on a synthetic on-disk CSV where that matters (b/c/d),
    or directly through gate() where only the binning logic is under test
    (e/f/g/h). Letters refer to the task spec this function was written
    against; kept in comments only, not asserted anywhere else.
    """
    print("\nB3 regressions:")

    def run_csv(lines):
        fd, path = tempfile.mkstemp(prefix="ig_selftest_", suffix=".csv")
        try:
            with os.fdopen(fd, "w") as f:
                f.write("\n".join(lines) + "\n")
            warn = {}
            conns = load_connections(path, warn=warn)
            return conns, warn
        finally:
            os.unlink(path)

    # (a) ordinary full-format series, no anomalies -> VALID.
    # (Also exercised at the gate() level by the pre-existing "flat series"
    # and jitter cases above; this repeats it through the CSV/load_connections
    # path for full end-to-end coverage of the normal 9-field row shape.)
    lines_a = [_normal_row("19700101000000", "50001", "7", float(t), float(t + 1),
                            1000, 1000) for t in range(60)]
    conns_a, warn_a = run_csv(lines_a)
    chk("(a) full-format series, no anomalies, via CSV", gate(conns_a["50001"])[0], "VALID")
    chk("(a) no orphan warning on clean file", bool(warn_a.get("orphan_transfer_ids")), False)

    # (b) explicit short (6-field) zero-throughput rows, correctly attributed
    # via the id->port map, land inside one full bin and depress it ->
    # INVALID. (With the pre-fix parser these rows were dropped outright,
    # which would NOT depress anything -- see step 2 for that comparison.)
    lines_b = []
    for t in range(70):
        if 30 <= t <= 33:
            lines_b.append(_short_row("19700101000000", "7", float(t), float(t + 1)))
        else:
            lines_b.append(_normal_row("19700101000000", "50001", "7", float(t), float(t + 1),
                                        1000, 1000))
    conns_b, warn_b = run_csv(lines_b)
    chk("(b) short zero rows attributed via id map -> INVALID", gate(conns_b["50001"])[0], "INVALID")
    chk("(b) no orphans in this file", bool(warn_b.get("orphan_transfer_ids")), False)
    chk("(b) all 70 seconds recovered for the connection", len(conns_b["50001"]), 70)

    # (c) two simultaneous connections in one file; short zero rows exist
    # ONLY for connection B (transfer id 8 / port 50002). Connection A
    # (transfer id 7 / port 50001) must come out completely unaffected: same
    # length, same values, VALID -- the short rows for B must never leak into
    # A's series via a wrong id->port lookup.
    lines_c = []
    for t in range(70):
        lines_c.append(_normal_row("19700101000000", "50001", "7", float(t), float(t + 1),
                                    1000, 1000))
        if 10 <= t <= 13:
            lines_c.append(_short_row("19700101000000", "8", float(t), float(t + 1)))
        else:
            lines_c.append(_normal_row("19700101000000", "50002", "8", float(t), float(t + 1),
                                        1000, 1000))
    conns_c, warn_c = run_csv(lines_c)
    chk("(c) connection A (no short rows) length unaffected", len(conns_c["50001"]), 70)
    chk("(c) connection A (no short rows) -> VALID", gate(conns_c["50001"])[0], "VALID")
    chk("(c) connection A values all 1000 (untouched by B's zeros)",
        all(b == 1000 for _, _, b in conns_c["50001"]), True)
    chk("(c) connection B (has short rows) -> INVALID", gate(conns_c["50002"])[0], "INVALID")
    chk("(c) connection B length unaffected (zeros recovered, not lost)", len(conns_c["50002"]), 70)

    # (d) a short row whose transfer id matches no well-formed row anywhere
    # in the file: the orphan case. Must be dropped (not absorbed into any
    # connection) and surfaced via `warn`, not silently discarded.
    lines_d = list(lines_a)  # clean 1-connection file, transfer id "7" only
    lines_d.append(_short_row("19700101000000", "99", 61.0, 62.0))
    conns_d, warn_d = run_csv(lines_d)
    chk("(d) orphan short row not absorbed into connection 50001", len(conns_d["50001"]), 60)
    chk("(d) orphan short row did not create a phantom connection", len(conns_d), 1)
    chk("(d) orphan transfer id surfaced via warn", warn_d.get("orphan_transfer_ids"), ["99"])

    # (e) a collapse located inside a COMPLETE (full-length) bin -> INVALID.
    # Already covered above by "4s collapse to 3% of median" (seconds
    # 20-23 fall inside full 5s bins at discard=3/bin=5); re-asserted here
    # by name for explicit B3-task traceability, same fixture.
    coll_full_bin = [("", float(t), 1000) for t in range(60)]
    for t in (20, 21, 22, 23):
        coll_full_bin[t] = ("", float(t), 30)
    chk("(e) collapse inside a complete bin -> INVALID", gate(coll_full_bin)[0], "INVALID")

    # (f) a collapse located ONLY inside the trailing partial bin -> INVALID.
    # This is the specific defect the trailing-bin fix targets: 42 seconds
    # total, discard=3 leaves kept t=3..41 (39 intervals): 7 full 5s bins
    # (kept idx 0-34, t=3..37) plus a trailing 4-element bin (kept idx
    # 35-38, t=38..41). The collapse sits ONLY in that trailing remainder.
    rows_f = [("", float(t), 1000) for t in range(42)]
    for t in (38, 39, 40, 41):
        rows_f[t] = ("", float(t), 30)
    verdict_f, reason_f, detail_f = gate(rows_f)
    chk("(f) collapse confined to the trailing partial bin -> INVALID", verdict_f, "INVALID")
    if detail_f:
        trailing_len = 39 - 7 * 5  # kept count - (full bins * binsec)
        chk("(f) trailing bin really is partial (4 of 5s)", trailing_len, 4)

    # (g) a CLEAN (non-collapsed) trailing partial bin -> VALID. A short
    # trailing bin must not spuriously fail merely for being short / having
    # fewer samples than a full bin.
    rows_g = [("", float(t), 1000) for t in range(42)]  # same shape as (f), no collapse
    chk("(g) clean trailing partial bin -> VALID", gate(rows_g)[0], "VALID")

    # (h) post-discard coverage below the 2-bin minimum -> INSUFFICIENT.
    # Already covered above by "too few intervals"; re-asserted here by name
    # for explicit B3-task traceability, same fixture (first 6 of `flat`).
    flat60 = [("", float(t), 1000) for t in range(60)]
    chk("(h) below 2-bin minimum after discard -> INSUFFICIENT",
        gate(flat60[:6], discard=3)[0], "INSUFFICIENT")


def selftest():
    """Tests on synthetic series plus the archived, intervention-labelled B1 arms."""
    ok = True

    def chk(name, got, want):
        nonlocal ok
        good = got == want
        ok = ok and good
        print("  %-52s %-12s %s" % (name, got, "OK" if good else "FAIL want=%s" % want))

    print("synthetic:")
    flat = [("", float(t), 1000) for t in range(60)]
    chk("flat series", gate(flat)[0], "VALID")
    chk("flat, +-4.3% jitter (L0/100ms normal)",
        gate([("", float(t), 1000 + (43 if t % 2 else -43)) for t in range(60)])[0], "VALID")
    # 500ms-cell quantization: undisturbed values are only {50,100,150}% of median
    import itertools
    q = [("", float(t), v) for t, v in
         zip(range(60), itertools.cycle([1000, 500, 1500, 1000, 1000, 500, 1500, 1000]))]
    chk("500ms-cell 1-window quantization (50/150%)", gate(q)[0], "VALID")
    coll = list(flat)
    for t in (20, 21, 22, 23):
        coll[t] = ("", float(t), 30)
    chk("4s collapse to 3% of median", gate(coll)[0], "INVALID")
    tr = [("", 0.0, 200), ("", 1.0, 700), ("", 2.0, 950)] + [("", float(t), 1000) for t in range(3, 60)]
    chk("slow start inside the discard window", gate(tr)[0], "VALID")
    chk("too few intervals", gate(flat[:6], discard=3)[0], "INSUFFICIENT")

    selftest_b3_regressions(chk)

    base = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        ".." , "..", "..", "..", "docs", "tfg_evidence", "raw_logs", "b1_capture")
    # KNOWN, TRACKED, INTENTIONAL FAILURE (not a regression to chase):
    # LOAD runs 4 and 5 report INSUFFICIENT ("run median is zero"), not
    # INVALID, as of the 2026-10-07 B3 fix: those two runs are 93-94%
    # zero-throughput over a 3.5x-longer span than runs 1-3 (see
    # docs/tfg_evidence/11_open_problems.md B4), so their own median is
    # zero and the median-relative INVALID rule cannot apply -- the
    # distinction is real evidence (B4), not a bug in this gate, and
    # `want` is deliberately left at the strict intervention label
    # (disturbed -> should be rejected) rather than widened to accept
    # INSUFFICIENT, so this discrepancy stays visible on every run instead
    # of being silently absorbed. `collect_run_meta.sh` treats INVALID and
    # INSUFFICIENT identically (both reject the run) -- see B3's Resolved
    # entry. SELFTEST FAILED below is therefore expected, not alarming.
    for arm, want in (("idle", "VALID"), ("load", "INVALID")):
        p = os.path.join(base, "host_%s.csv" % arm)
        if not os.path.exists(p):
            print("  (archived B1 %s arm not found, skipped)" % arm); continue
        print("archived B1 %s arm (labels set by intervention, not inspection):" % arm.upper())
        warn = {}
        conns = load_connections(p, warn=warn)
        if warn.get("orphan_transfer_ids"):
            print("  WARNING orphan transfer ids (unattributable short rows): %s"
                  % warn["orphan_transfer_ids"])
        for i, (k, rows) in enumerate(conns.items(), 1):
            chk("  %s run %d" % (arm, i), gate(rows)[0], want)

    # Informational-only sweep of every real host-iperf CSV in the archive,
    # to surface orphan-transfer-id short rows (see load_connections
    # docstring). No ground-truth collapse labels exist for these files, so
    # nothing here is asserted pass/fail -- it only reports what exists.
    archive = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "..", "..", "..", "docs", "tfg_evidence", "raw_logs")
    print("\narchive-wide orphan-transfer-id scan (informational, no labels):")
    any_orphans = False
    for root, _, files in sorted(os.walk(archive)):
        for name in sorted(files):
            if "host" not in name or not name.endswith(".csv"):
                continue
            p = os.path.join(root, name)
            warn = {}
            load_connections(p, warn=warn)
            if warn.get("orphan_transfer_ids"):
                any_orphans = True
                print("  %s: orphan transfer ids %s" % (p, warn["orphan_transfer_ids"]))
    if not any_orphans:
        print("  none found")

    print("\nSELFTEST %s" % ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
