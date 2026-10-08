#!/usr/bin/env python3
"""
Compute the discard-windowed mech_app_limited / mech_unsent_pending /
mech_ack_pending fractions for ONE run, from its instr_dump JSON and its
per-sample trace (instr_trace output). This is the primary-evidence
windowing step the frozen `discard_interval_s` applies to -- distinct
from, and currently NOT wired into, N8's own discard/bin logic in
interval_gate.py, which only ever operated on the host per-second
throughput CSV, never on the guest sender-state trace.

Required because `instr_dump`'s own accumulators cover the WHOLE run
from `instr_reset` to `instr_dump` -- they cannot retroactively exclude
the first `discard_interval_s` seconds. Only the per-sample trace can,
since it carries each sample's own tick. This script applies the exact
discard-window method already used (and independently re-verified by
hand multiple times) throughout docs/tfg_evidence/13_pilot_20ms.md and
12_phase0_measurements.md's "Repetitions planning objective" section:

  window = [first_sample_tick + discard_s * tick_per_second,
            first_sample_tick + duration_s * tick_per_second)

  per-sample classification (applications/instr.c, the sampler's own
  rule, lines ~388-392):
    snd_buf > 0        -> app_limited
    elif unsent > 0    -> unsent_pending
    else               -> ack_pending

Usage:
  compute_discard_windowed_mechfrac.py <instr_dump.json> <trace_file> \
      [--discard SECONDS] [--duration SECONDS]

Defaults: --discard 3 --duration 60, matching manifest.yaml's frozen
tbd_from_pilot.discard_interval_s / run_duration_s as of 2026-10-08. Pass
explicit values if either is ever re-frozen to something else -- this
script does not hardcode the manifest, it takes them as arguments so it
cannot silently drift from a future refreeze.

Prints one line: a JSON object with the windowed counts/fractions, the
whole-run (unwindowed) counts/fractions for cross-check (never silently
replacing one with the other -- manifest.yaml's own
invalid_run_replacement_policy section and the broader project
convention both require preserving the original accumulators alongside
any derived quantity), and the actual kept-sample count so a caller can
tell a thin window (e.g. a short/overrun run) from a normal one.

Exit codes: 0 = computed successfully. 1 = malformed/missing input
(reported on stderr, nothing printed on stdout). This script makes no
VALID/INVALID/VALID_ANOMALOUS determination -- that is collect_run_meta.sh's
job, using whatever gates are actually frozen; this script only computes
a number that a gate or an analysis step can use. It is not a new
detector.
"""
import sys
import json
import argparse


def load_trace_rows(path):
    """Yield (n, tick, snd_buf, cwnd, snd_wnd, queuelen, unsent, inflight)
    tuples for every real data row. Tolerant of the BEGIN/header/END
    marker lines instr_trace emits around the data, exactly like every
    other trace reader in this project (interval_gate.py's test harness,
    analyse_b4_timeline.py, analyse_mechfrac_variance.py)."""
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            parts = line.split(',')
            if len(parts) == 8 and parts[0].isdigit() and parts[1].isdigit():
                rows.append(tuple(int(p) for p in parts))
    return rows


def classify(snd_buf, unsent):
    if snd_buf > 0:
        return 'app_limited'
    elif unsent > 0:
        return 'unsent_pending'
    else:
        return 'ack_pending'


def fractions(rows):
    n = len(rows)
    if n == 0:
        return None
    counts = {'app_limited': 0, 'unsent_pending': 0, 'ack_pending': 0}
    for _, _tick, snd_buf, _cwnd, _snd_wnd, _queuelen, unsent, _inflight in rows:
        counts[classify(snd_buf, unsent)] += 1
    return {
        'n': n,
        'counts': counts,
        'fraction_pct': {k: 100.0 * v / n for k, v in counts.items()},
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('instr_json')
    ap.add_argument('trace_file')
    ap.add_argument('--discard', type=float, default=3.0,
                     help='seconds to exclude from the start (default 3, '
                          'matching manifest.yaml tbd_from_pilot.discard_interval_s)')
    ap.add_argument('--duration', type=float, default=60.0,
                     help='requested run duration in seconds, used as the '
                          'window end (default 60, matching '
                          'tbd_from_pilot.run_duration_s). The window end '
                          'is first_sample_tick + duration*tick_per_second '
                          'regardless of how long the run actually ran -- '
                          'an overrun run (see pilot20_L0_r50_1,'
                          ' docs/tfg_evidence/13_pilot_20ms.md) is handled '
                          'correctly: samples past the window end are '
                          'excluded from the windowed figure but still '
                          'counted in the whole-run figure for cross-check.')
    args = ap.parse_args()

    try:
        with open(args.instr_json) as f:
            text = f.read()
        import re
        m = re.search(r'\{.*\}', text, re.S)
        if not m:
            print('FATAL: no JSON object found in %s' % args.instr_json, file=sys.stderr)
            return 1
        j = json.loads(m.group(0))
    except Exception as e:
        print('FATAL: could not parse %s: %s' % (args.instr_json, e), file=sys.stderr)
        return 1

    try:
        first_tick = j['first_sample_tick']
        tick_per_second = j['sampler']['tick_per_second']
        sample_count = j['sample_count']
    except KeyError as e:
        print('FATAL: instr_dump JSON missing required field %s' % e, file=sys.stderr)
        return 1

    try:
        rows = load_trace_rows(args.trace_file)
    except OSError as e:
        print('FATAL: could not read trace %s: %s' % (args.trace_file, e), file=sys.stderr)
        return 1

    if not rows:
        print('FATAL: no data rows parsed from %s' % args.trace_file, file=sys.stderr)
        return 1

    # Whole-run (unwindowed) cross-check, from the trace itself -- should
    # match instr_dump's own mech_* fields exactly when the trace is
    # complete (trace_written == sample_count); report both so a caller
    # can see a mismatch rather than assume completeness.
    whole_run = fractions(rows)

    lo_tick = first_tick + args.discard * tick_per_second
    hi_tick = first_tick + args.duration * tick_per_second
    windowed_rows = [r for r in rows if lo_tick <= r[1] < hi_tick]
    windowed = fractions(windowed_rows)

    out = {
        'run_id': j.get('run_id'),
        'discard_s': args.discard,
        'duration_s': args.duration,
        'tick_per_second': tick_per_second,
        'first_sample_tick': first_tick,
        'instr_dump_sample_count': sample_count,
        'trace_rows_read': len(rows),
        'trace_complete': len(rows) == sample_count,
        'windowed': windowed,
        'whole_run_from_trace': whole_run,
        'whole_run_from_instr_dump': {
            'n': sample_count,
            'counts': {
                'app_limited': j.get('mech_app_limited'),
                'unsent_pending': j.get('mech_unsent_pending'),
                'ack_pending': j.get('mech_ack_pending'),
            },
        },
    }
    if windowed is None:
        print('WARNING: zero samples fall inside the requested window '
              '[%.1f, %.1f)s -- windowed fractions are unavailable for '
              'this run (not necessarily a defect; report, do not invent)'
              % (args.discard, args.duration), file=sys.stderr)
    print(json.dumps(out, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
