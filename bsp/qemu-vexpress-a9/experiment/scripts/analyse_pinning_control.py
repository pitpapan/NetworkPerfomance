import json,os,sys,statistics,collections,subprocess
S="/tmp/claude-1000/-home-vboxuser-NetworkPerfomance-bsp-qemu-vexpress-a9/dff6857f-5b42-4cf4-853b-3dc89a92c2d6/scratchpad"
d=S+"/g6"
order=open(d+"/order.txt").read().split()
# host csv is per (cfg,cycle); runs within a file are in order 50,50,50,500,500,500
host={}
for f in os.listdir(d):
    if f.startswith("host_") and f.endswith(".csv"):
        key=f[5:-4]                      # e.g. STOCK_c1
        rows=subprocess.run([sys.executable,S+"/parse_iperf.py",d+"/"+f],
                            capture_output=True,text=True).stdout.strip().split("\n")
        host[key]=[r for r in rows if r]
rows=[]
idx=collections.Counter()
for rid in order:
    _,cyc,cfg,rtt,rep=rid.split("_")
    key="%s_%s"%(cfg,cyc)
    p=d+"/"+rid+".json"
    if not os.path.exists(p) or not os.path.getsize(p): print("MISSING",rid); continue
    j=json.load(open(p))
    i=idx[key]; idx[key]+=1
    bps=int(host[key][i].split(",")[3]) if i<len(host.get(key,[])) else None
    rows.append(dict(rid=rid,cfg=cfg,cyc=cyc,rtt=int(rtt[1:]),bps=bps,
        samp=j["sample_count"],gmin=j["gap_min_ticks"],gmax=j["gap_max_ticks"],
        stale=j["stale_count"],span=j["sample_span_ticks"],
        qlen=j["snd_queuelen_max"],sbmax=j["snd_buf_max"],
        une=j["unsent_nonempty_count"],ubmax=j["unsent_bytes_max"],
        unackbm=j["unacked_bytes_max"],nrtx=j["nrtx_max"],
        mal=j.get("mech_app_limited"),mup=j.get("mech_unsent_pending"),
        map_=j.get("mech_ack_pending"),sbz=j.get("snd_buf_zero_count"),
        sbgw=j.get("snd_buf_ge_write_count"),
        qmax_cfg=j["cfg"]["TCP_SND_QUEUELEN"],segcfg=j["cfg"]["MEMP_NUM_TCP_SEG"]))
print("=== G6 pinning control: STOCK 8196/22/40 vs PINNED 8196/44/44 ===")
print("Timing self-check:")
bad=0
for r in rows:
    exp=r["span"]//10+1
    if exp!=r["samp"]: bad+=1; print("  MISMATCH %s exp=%d got=%d"%(r["rid"],exp,r["samp"]))
print("  mismatches: %d / %d ; total stale=%d ; max nrtx=%d"%(bad,len(rows),
    sum(r["stale"] for r in rows),max(r["nrtx"] for r in rows)))
print()
print("--- CLAIM 3: did pinning perturb throughput at the tested points? ---")
print("%-8s %-6s %3s %11s %9s %7s %11s"%("cfg","rtt","n","mean_bps","sd","cv%","median"))
g=collections.OrderedDict()
for r in rows: g.setdefault((r["rtt"],r["cfg"]),[]).append(r)
for k in sorted(g,key=lambda x:(x[0],x[1])):
    rs=g[k]; b=[r["bps"] for r in rs if r["bps"]]
    m=statistics.mean(b); sd=statistics.stdev(b) if len(b)>1 else 0
    print("%-8s %-6s %3d %11.0f %9.0f %7.3f %11.0f"%(k[1],"%dms"%k[0],len(b),m,sd,100*sd/m,statistics.median(b)))
for rtt in sorted(set(r["rtt"] for r in rows)):
    s=[r["bps"] for r in g[(rtt,"STOCK")] if r["bps"]]
    p=[r["bps"] for r in g[(rtt,"PINNED")] if r["bps"]]
    ms,mp=statistics.median(s),statistics.median(p)
    print("  %dms: PINNED-STOCK on medians = %+.0f bps (%+.3f%%)"%(rtt,mp-ms,100*(mp-ms)/ms))
print()
print("--- CLAIMS 1 and 2: did the limit bind? (high-water vs the configured limit) ---")
print("%-8s %-6s %-14s %-14s %-12s %-12s"%("cfg","rtt","QUEUELEN cfg","qlen_high","SEG cfg","unsent_bmax"))
for k in sorted(g,key=lambda x:(x[0],x[1])):
    rs=g[k]
    print("%-8s %-6s %-14d %-14s %-12d %-12s"%(k[1],"%dms"%k[0],rs[0]["qmax_cfg"],
        "%d-%d"%(min(r["qlen"] for r in rs),max(r["qlen"] for r in rs)),
        rs[0]["segcfg"],"%d-%d"%(min(r["ubmax"] for r in rs),max(r["ubmax"] for r in rs))))
print()
print("--- G5 mechanism classification (new counters) ---")
print("%-8s %-6s %9s %14s %14s %12s %10s %10s"%("cfg","rtt","samp","app_limited","unsent_pend","ack_pend","sbuf==0","sbuf>=4096"))
for k in sorted(g,key=lambda x:(x[0],x[1])):
    rs=g[k]
    def s(f): return sum(r[f] or 0 for r in rs)
    tot=s("samp")
    print("%-8s %-6s %9d %14s %14s %12s %10s %10s"%(k[1],"%dms"%k[0],tot,
        "%d (%.2f%%)"%(s("mal"),100*s("mal")/tot),
        "%d (%.2f%%)"%(s("mup"),100*s("mup")/tot),
        "%d (%.1f%%)"%(s("map_"),100*s("map_")/tot),
        "%.2f%%"%(100*s("sbz")/tot), "%d"%s("sbgw")))
