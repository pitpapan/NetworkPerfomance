import sys,os,csv,statistics,collections,json,glob
d=sys.argv[1]; hostcsv=sys.argv[2]; pref=sys.argv[3]
runs=sorted(glob.glob(os.path.join(d,pref+"*.json")))
ids=[os.path.basename(p)[:-5] for p in runs]
# host per-interval, per connection in order
conns=collections.OrderedDict()
for line in open(hostcsv):
    f=line.strip().split(',')
    if len(f)<9: continue
    try: ts=f[0]; bps=int(f[8]); a,b=[float(x) for x in f[6].split('-')]
    except: continue
    if b-a>1.6: continue
    conns.setdefault(f[2],[]).append((ts,a,bps))
keys=list(conns.keys())
print("runs=%d host_connections=%d"%(len(ids),len(keys)))
for idx,rid in enumerate(ids):
    if idx>=len(keys): print("  %s: NO HOST DATA"%rid); continue
    v=conns[keys[idx]]
    ss=statistics.median([b for _,_,b in v])
    dips=[(ts,int(a),b,100.0*b/ss) for ts,a,b in v if b<0.80*ss and a>=2]
    j=json.load(open(os.path.join(d,rid+".json")))
    # guest trace: per-sample tick gaps
    gaps=[]
    tr=os.path.join(d,rid+".trace")
    prev=None
    if os.path.exists(tr):
        for line in open(tr):
            p=line.strip().split(',')
            if len(p)<8 or not p[0].isdigit(): continue
            t=int(p[1])
            if prev is not None and t-prev>10: gaps.append((int(p[0]),prev,t-prev))
            prev=t
    # host monitor
    mon={}
    mc=os.path.join(d,rid+".hostmon.csv")
    if os.path.exists(mc):
        for row in csv.DictReader(open(mc)): mon[row["ts"]]=row
    print("\n=== %s  steady_median=%d  dips<80%%=%d  guest_gap>nominal=%d  gap_max_ticks=%s  stale=%d nrtx=%d"%(
        rid,ss,len(dips),len(gaps),j["gap_max_ticks"],j["stale_count"],j["nrtx_max"]))
    if gaps:
        print("    guest timer slips (sample_n, tick, gap_ticks):", gaps[:10])
    for ts,a,b,pct in dips:
        m=mon.get(ts,{})
        print("    DIP t=%-3ds bps=%-9d (%5.1f%%) | qemu_rundelay=%-8s ms qemu_exec=%-8s ms slices=%-6s | cpu_idle=%-4s iowait=%-3s steal=%-3s ctxt=%-6s run=%-2s | iperf_rundelay=%-6s"%(
            a,b,pct,m.get("qemu_rundelay_ms","?"),m.get("qemu_exec_ms","?"),m.get("qemu_slices","?"),
            m.get("cpu_idle","?"),m.get("cpu_iowait","?"),m.get("cpu_steal","?"),
            m.get("ctxt","?"),m.get("procs_running","?"),m.get("iperf_rundelay_ms","?")))
# baseline stats for rundelay across all monitor rows
allrd=[]; 
for rid in ids:
    mc=os.path.join(d,rid+".hostmon.csv")
    if os.path.exists(mc):
        for row in csv.DictReader(open(mc)):
            try: allrd.append(float(row["qemu_rundelay_ms"]))
            except: pass
if allrd:
    allrd.sort()
    print("\n=== qemu_rundelay_ms distribution over ALL %d monitor seconds ==="%len(allrd))
    for q in (50,90,95,99,100):
        print("   p%-3d = %8.1f ms"%(q,allrd[min(len(allrd)-1,int(len(allrd)*q/100.0))]))
    print("   mean = %.1f ms"%statistics.mean(allrd))
