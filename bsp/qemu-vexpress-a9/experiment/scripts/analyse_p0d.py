import json,os,sys,collections,statistics
d=sys.argv[1]; cfg=sys.argv[2]
order=open(d+"/order_%s.txt"%cfg).read().split()
print("=== %s : instr_dump summary ==="%cfg)
print("%-22s %6s %5s %5s %9s %9s %9s %8s %8s %8s %8s"%("run","samp","gmin","gmax","sbuf_max","sbuf_mnx","qlen_max","uns_ne","uns_bmax","unack_bm","cwnd_max"))
for rid in order:
    p=d+"/"+rid+".json"
    if not os.path.exists(p) or os.path.getsize(p)==0: print("  MISSING",rid); continue
    j=json.load(open(p))
    print("%-22s %6d %5d %5d %9d %9d %8d %8d %8d %8d %8d"%(rid,j["sample_count"],
      j["gap_min_ticks"],j["gap_max_ticks"],j["snd_buf_max"],j["snd_buf_mean_x1000"],
      j["snd_queuelen_max"],j["unsent_nonempty_count"],j["unsent_bytes_max"],
      j["unacked_bytes_max"],j["cwnd_max"]))
    it=max(1,j["sampler"]["interval_ms"]*100//1000)
    exp=j["sample_span_ticks"]//it+1
    if exp!=j["sample_count"]: print("     TIMING MISMATCH exp=%d got=%d"%(exp,j["sample_count"]))

# transient analysis from host per-interval
print("\n=== %s : per-second host throughput, long runs (transient onset) ==="%cfg)
conns=collections.OrderedDict()
for line in open(d+"/host_%s.csv"%cfg):
    f=line.strip().split(',')
    if len(f)<9: continue
    try: bps=int(f[8]); a,b=[float(x) for x in f[6].split('-')]
    except: continue
    if b-a>1.6: continue
    conns.setdefault(f[2],[]).append((a,bps))
longs=[rid for rid in order if rid.endswith("t100")]
keys=list(conns.keys())
# long runs are every other connection (t100 then i10)
for i,rid in enumerate(longs):
    k=keys[i*2] if i*2<len(keys) else None
    if k is None: continue
    v=conns[k]
    ss=statistics.median([b for a,b in v if a>=30])   # reference: last 60s
    print("\n%s  n_int=%d  median_bps(t>=30s)=%d"%(rid,len(v),ss))
    print("  first 20s: "+" ".join("%d"%b for a,b in v[:20]))
    # onset: first t where all subsequent intervals are within +-5% of ss
    onset=None
    for t in range(0,len(v)):
        if all(abs(b-ss)<=0.05*ss for a,b in v[t:]): onset=v[t][0]; break
    print("  first interval from which ALL later intervals are within +-5%% of that median: t=%s"%onset)
