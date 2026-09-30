import json, os, statistics, collections, subprocess, sys

# Usage: analyse_interval_sweep.py <run_dir>
# <run_dir> holds order.txt, host.csv and one <run_id>.json per run.
d = sys.argv[1]
S = os.path.dirname(os.path.abspath(__file__))
order = open(d + "/order.txt").read().split()
host = subprocess.run([sys.executable, S + "/parse_iperf.py", d + "/host.csv"],
                      capture_output=True, text=True).stdout.strip().split("\n")
rows = []
for i, rid in enumerate(order):
    j = json.load(open(d + "/" + rid + ".json"))
    rows.append(dict(rid=rid, arm=rid.rsplit("_", 1)[-1], bps=int(host[i].split(",")[3]),
                     samp=j["sample_count"], gmin=j["gap_min_ticks"], gmax=j["gap_max_ticks"],
                     ival=j["sampler"]["interval_ms"], stale=j["stale_count"],
                     sbmax=j["snd_buf_max"], sbmean=j["snd_buf_mean_x1000"],
                     une=j["unsent_nonempty_count"], span=j["sample_span_ticks"]))
g = collections.OrderedDict()
for r in rows:
    g.setdefault(r["arm"], []).append(r)
A = ["off100", "full10", "full20", "full50", "full100", "full500"]
print("%-9s %2s %11s %9s %7s %11s %9s %6s %6s %11s %9s" % (
    "arm", "n", "mean_bps", "sd", "cv%", "median_bps", "samp", "gap", "stale", "snbuf_max", "unsent_ne"))
print("-" * 104)
for a in A:
    rs = g[a]
    b = [r["bps"] for r in rs]
    m = statistics.mean(b)
    sd = statistics.stdev(b)
    print("%-9s %2d %11.0f %9.0f %7.3f %11.0f %9s %6s %6d %11s %9s" % (
        a, len(b), m, sd, 100 * sd / m, statistics.median(b),
        "%d-%d" % (min(r["samp"] for r in rs), max(r["samp"] for r in rs)),
        "%d/%d" % (min(r["gmin"] for r in rs), max(r["gmax"] for r in rs)),
        sum(r["stale"] for r in rs),
        "%d-%d" % (min(r["sbmax"] for r in rs), max(r["sbmax"] for r in rs)),
        "%d-%d" % (min(r["une"] for r in rs), max(r["une"] for r in rs))))
off = statistics.median([r["bps"] for r in g["off100"]])
print("\nDeltas vs OFF median (%.0f bps):" % off)
for a in A[1:]:
    med = statistics.median([r["bps"] for r in g[a]])
    print("  %-9s median=%-9.0f delta=%+8.0f (%+.3f%%)" % (a, med, med - off, 100 * (med - off) / off))
print("\nper-run bps:")
for a in A:
    print("  %-9s %s" % (a, " ".join("%d" % r["bps"] for r in g[a])))
print("\nsnd_buf_mean_x1000 per run (resolution proxy):")
for a in A:
    print("  %-9s %s" % (a, " ".join("%d" % r["sbmean"] for r in g[a])))
