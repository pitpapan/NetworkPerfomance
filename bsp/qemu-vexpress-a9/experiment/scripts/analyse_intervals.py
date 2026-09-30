#!/usr/bin/env python3
"""Per-interval analysis of iperf2 -y C output, grouped by connection in order.
Usage: intervals.py <host.csv> [order.txt]"""
import sys, collections, statistics
conns = collections.OrderedDict()
for line in open(sys.argv[1]):
    f = line.strip().split(',')
    if len(f) < 9: continue
    try: by = int(f[7]); bps = int(f[8])
    except ValueError: continue
    iv = f[6]
    try: a, b = [float(x) for x in iv.split('-')]
    except ValueError: continue
    conns.setdefault(f[2], []).append((a, b, by, bps))
order = open(sys.argv[2]).read().split() if len(sys.argv) > 2 else None

# drop each connection's summary row (the one spanning 0.0 -> end, when others exist)
clean = collections.OrderedDict()
for k, v in conns.items():
    per = [r for r in v if (r[1] - r[0]) <= 1.6]
    clean[k] = (per, [r for r in v if (r[1]-r[0]) > 1.6])
print("connections=%d" % len(clean))
names = order if order and len(order) == len(clean) else list(clean.keys())

print("\n--- per-interval bps, first 12 intervals of each connection ---")
for n, (k, (per, _)) in zip(names, clean.items()):
    print("  %-16s %s" % (n, " ".join("%d" % r[3] for r in per[:12])))

print("\n--- mean bps over intervals starting at or after T (drop first T seconds) ---")
Ts = [0,1,2,3,4,5,6,8,10]
print("  %-16s %s" % ("run", " ".join("T=%-8d" % t for t in Ts)))
for n, (k, (per, _)) in zip(names, clean.items()):
    vals = []
    for t in Ts:
        sel = [r[3] for r in per if r[0] >= t]
        vals.append(statistics.mean(sel) if sel else float('nan'))
    print("  %-16s %s" % (n, " ".join("%-10.0f" % v for v in vals)))

if order:
    print("\n--- group means by tier, over intervals with start >= T ---")
    for t in Ts:
        g = collections.OrderedDict()
        for n, (k, (per, _)) in zip(names, clean.items()):
            tier = n.rsplit("_", 1)[-1]
            sel = [r[3] for r in per if r[0] >= t]
            if sel: g.setdefault(tier, []).append(statistics.mean(sel))
        out = []
        for tier, xs in g.items():
            m = statistics.mean(xs); sd = statistics.stdev(xs) if len(xs) > 1 else 0
            out.append("%s=%.0f(sd%.0f,cv%.3f%%)" % (tier, m, sd, 100*sd/m))
        print("  T=%-3d %s" % (t, "  ".join(out)))
