#!/usr/bin/env python3
"""Join per-run instr_dump JSON with the host-side iperf CSV summaries (by order)
and report per-group statistics. Usage: analyse.py <dir> <groupfield>
groupfield: a callable name known below, applied to run_id."""
import sys, os, json, glob, statistics, collections, subprocess

d = sys.argv[1]
grouper = sys.argv[2] if len(sys.argv) > 2 else "tier"

order = open(os.path.join(d, "order.txt")).read().split()
host = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "parse_iperf.py"),
                       os.path.join(d, "host.csv")], capture_output=True, text=True).stdout.strip().split("\n")
host = [h for h in host if h]

rows = []
for i, rid in enumerate(order):
    p = os.path.join(d, rid + ".json")
    if not os.path.exists(p):
        print("MISSING dump: %s" % rid); continue
    j = json.load(open(p))
    r = {"run_id": rid, "idx": i}
    r.update({k: v for k, v in j.items() if k not in ("cfg", "sampler")})
    r["interval_ms"] = j["sampler"]["interval_ms"]
    r["tier"] = j["sampler"]["tier"]
    r["snd_buf"] = j["cfg"]["TCP_SND_BUF"]
    if i < len(host):
        port, iv, by, bps = host[i].split(",")
        r["host_port"] = port; r["host_interval"] = iv
        r["host_bytes"] = int(by); r["host_bps"] = int(bps)
    rows.append(r)

def key(r):
    if grouper == "tier":     return {0: "off", 1: "floor", 2: "full"}[r["tier"]]
    if grouper == "interval": return "%dms" % r["interval_ms"]
    if grouper == "sndbuf":   return "buf%d" % r["snd_buf"]
    return "all"

g = collections.OrderedDict()
for r in rows: g.setdefault(key(r), []).append(r)

print("n_runs=%d  n_host_rows=%d" % (len(rows), len(host)))
print()
hdr = "%-10s %3s %12s %10s %8s %10s %7s %7s %7s %6s %6s" % (
    "group","n","mean_bps","sd_bps","cv%","min..max_bps","samp","gapmin","gapmax","stale","nrtx")
print(hdr); print("-"*len(hdr))
for k, rs in g.items():
    b = [r["host_bps"] for r in rs if "host_bps" in r]
    if not b: continue
    m = statistics.mean(b); sd = statistics.stdev(b) if len(b) > 1 else 0.0
    print("%-10s %3d %12.0f %10.1f %8.3f %10s %7s %7s %7s %6d %6d" % (
        k, len(b), m, sd, 100*sd/m if m else 0,
        "%d..%d" % (min(b), max(b)),
        "%d-%d" % (min(r["sample_count"] for r in rs), max(r["sample_count"] for r in rs)),
        min(r["gap_min_ticks"] for r in rs), max(r["gap_max_ticks"] for r in rs),
        sum(r["stale_count"] for r in rs), max(r["nrtx_max"] for r in rs)))
print()
print("--- timing self-check per run (expected = span/interval_ticks + 1) ---")
bad = 0
for r in rows:
    it = max(1, r["interval_ms"] * 100 // 1000)
    exp = r["sample_span_ticks"] // it + 1 if r["sample_count"] else 0
    ok = "OK" if exp == r["sample_count"] else "MISMATCH"
    if exp != r["sample_count"]: bad += 1; print("  %-16s span=%-6d ival_t=%-3d exp=%-5d got=%-5d %s" % (
        r["run_id"], r["sample_span_ticks"], it, exp, r["sample_count"], ok))
print("  runs with mismatch: %d / %d" % (bad, len(rows)))
print()
print("--- mechanism fields (min..max across runs per group) ---")
for k, rs in g.items():
    def mm(f): return "%d..%d" % (min(r[f] for r in rs), max(r[f] for r in rs))
    print("  %-10s snd_buf_max=%-9s snd_buf_mean_x1000=%-12s queuelen_max=%-7s unsent_ne=%-9s unsent_bmax=%-8s unacked_bmax=%s" % (
        k, mm("snd_buf_max"), mm("snd_buf_mean_x1000"), mm("snd_queuelen_max"),
        mm("unsent_nonempty_count"), mm("unsent_bytes_max"), mm("unacked_bytes_max")))
print()
print("--- per-run detail ---")
for r in rows:
    print("  %-16s tier=%d ival=%-4d bps=%-9s samp=%-5d gap=%d/%d snbufmax=%-6d unsent_ne=%-5d unsent_bmax=%-6d" % (
        r["run_id"], r["tier"], r["interval_ms"], r.get("host_bps","?"), r["sample_count"],
        r["gap_min_ticks"], r["gap_max_ticks"], r["snd_buf_max"],
        r["unsent_nonempty_count"], r["unsent_bytes_max"]))
