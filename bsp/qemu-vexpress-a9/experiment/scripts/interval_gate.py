#!/usr/bin/env python3
"""
N8 -- per-interval validity gate for a Phase 0/1 run.

THE RULE (parameters are proposals, not decisions; see
docs/tfg_evidence/12_phase0_measurements.md):

  1. Drop the first D seconds of per-second host intervals (startup transient).
     The transient and later disturbances are handled by DIFFERENT mechanisms:
     the transient is excluded by D, disturbances are detected after D.
  2. Aggregate the remaining intervals into consecutive non-overlapping bins of
     B seconds (mean bps over the bin); drop a short trailing bin.

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
import sys, os, collections, statistics

DEFAULT_DISCARD = 3      # s   PROPOSAL -- manifest slot stays null
DEFAULT_BIN     = 5      # s   PROPOSAL -- manifest slot stays null
DEFAULT_BAND    = 0.80   #     PROPOSAL -- manifest slot stays null
DEFAULT_ALLOW   = 0      #     PROPOSAL -- manifest slot stays null


def load_connections(path):
    """Return OrderedDict{src_port: [(ts, t_start, bps)]} of per-second rows only."""
    conns = collections.OrderedDict()
    for line in open(path):
        f = line.strip().split(',')
        if len(f) < 9:
            continue
        try:
            bps = int(f[8])
            a, b = [float(x) for x in f[6].split('-')]
        except ValueError:
            continue
        if b - a > 1.6:          # the per-connection summary row, not an interval
            continue
        conns.setdefault(f[2], []).append((f[0], a, bps))
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
    for i in range(0, len(kept) - binsec + 1, binsec):
        chunk = kept[i:i + binsec]
        bins.append((chunk[0][0], int(chunk[0][1]),
                     sum(c[2] for c in chunk) / float(len(chunk))))
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
    conns = load_connections(path)
    keys = list(conns.keys())
    if idx >= len(keys):
        print("INSUFFICIENT no connection at index %d (found %d)" % (idx, len(keys)))
        return 1
    verdict, reason, d = gate(conns[keys[idx]], **kw)
    print("%s %s" % (verdict, reason))
    return {"VALID": 0, "INVALID": 2}.get(verdict, 1)


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

    base = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        ".." , "..", "..", "..", "docs", "tfg_evidence", "raw_logs", "b1_capture")
    for arm, want in (("idle", "VALID"), ("load", "INVALID")):
        p = os.path.join(base, "host_%s.csv" % arm)
        if not os.path.exists(p):
            print("  (archived B1 %s arm not found, skipped)" % arm); continue
        print("archived B1 %s arm (labels set by intervention, not inspection):" % arm.upper())
        conns = load_connections(p)
        for i, (k, rows) in enumerate(conns.items(), 1):
            chk("  %s run %d" % (arm, i), gate(rows)[0], want)
    print("\nSELFTEST %s" % ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
