import sys,collections,statistics
d=sys.argv[1]; cfg=sys.argv[2]
order=open(d+"/order_%s.txt"%cfg).read().split()
longs=[r for r in order if r.endswith("t100")]
conns=collections.OrderedDict()
for line in open(d+"/host_%s.csv"%cfg):
    f=line.strip().split(',')
    if len(f)<9: continue
    try: bps=int(f[8]); a,b=[float(x) for x in f[6].split('-')]
    except: continue
    if b-a>1.6: continue
    conns.setdefault(f[2],[]).append((a,bps))
keys=list(conns.keys())
print("%-20s %10s %7s %7s %9s  %s"%("run","ss_median","first>=","first>=","n_below","late dips (t:bps)"))
print("%-20s %10s %7s %7s %9s"%("","(t>=30s)","95%","99%","95% after"))
for i,rid in enumerate(longs):
    v=conns[keys[i*2]]
    ss=statistics.median([b for a,b in v if a>=30])
    f95=next((a for a,b in v if b>=0.95*ss),None)
    f99=next((a for a,b in v if b>=0.99*ss),None)
    dips=[(int(a),b) for a,b in v if a>(f95 or 0) and b<0.95*ss]
    print("%-20s %10d %7s %7s %9d  %s"%(rid,ss,f95,f99,len(dips),
        " ".join("%d:%d"%x for x in dips[:8])))
