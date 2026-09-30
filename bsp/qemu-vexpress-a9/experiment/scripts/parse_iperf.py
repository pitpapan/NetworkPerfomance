#!/usr/bin/env python3
"""Parse iperf2 -y C CSV. Emit one row per connection (the summary line),
in connection order. Fields: ts,localip,localport,remoteip,remoteport,id,interval,bytes,bps
NOTE: with -y C the 'local' columns are the DATA SENDER as seen by the server."""
import sys, collections
rows = collections.OrderedDict()
for line in open(sys.argv[1]):
    f = line.strip().split(',')
    if len(f) < 9: continue
    try: int(f[7]); int(f[8])
    except ValueError: continue
    key = f[2]                      # sender source port = connection identity
    rows[key] = f                   # last line for this port wins = summary
for k, f in rows.items():
    print("%s,%s,%s,%s" % (k, f[6], f[7], f[8]))
