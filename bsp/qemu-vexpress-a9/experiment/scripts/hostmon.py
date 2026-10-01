#!/usr/bin/env python3
"""1 Hz host telemetry for B1 capture. One process, reads /proc only.
Time base: wall clock YYYYMMDDHHMMSS, identical to iperf2 -y C column 0.

Emitted per second (deltas since previous sample unless noted):
  ts, unix, cpu_user..cpu_steal (jiffies), ctxt, procs_running(inst),
  procs_blocked(inst), load1(inst),
  qemu_exec_ms, qemu_rundelay_ms, qemu_slices,   <- summed over ALL qemu threads
  iperf_exec_ms, iperf_rundelay_ms, iperf_slices
run_delay is time the task was RUNNABLE BUT NOT RUNNING (ns in /proc). A
spike there means the process was starved, which is the discriminator
between "the VM stalled" and "the network path misbehaved".
Usage: hostmon.py <qemu_pid> <iperf_pid> <out.csv>
"""
import sys, time, os

qpid, ipid, out = sys.argv[1], sys.argv[2], sys.argv[3]

def schedstat_sum(pid):
    """Sum schedstat over all threads of pid. Returns (exec_ns, delay_ns, slices)."""
    e = d = c = 0
    try:
        for t in os.listdir("/proc/%s/task" % pid):
            try:
                f = open("/proc/%s/task/%s/schedstat" % (pid, t)).read().split()
                e += int(f[0]); d += int(f[1]); c += int(f[2])
            except (IOError, OSError, IndexError):
                pass
    except (IOError, OSError):
        pass
    return e, d, c

def procstat():
    ctxt = 0; run = 0; blk = 0; cpu = []
    for line in open("/proc/stat"):
        if line.startswith("cpu "):
            cpu = [int(x) for x in line.split()[1:9]]
        elif line.startswith("ctxt"):
            ctxt = int(line.split()[1])
        elif line.startswith("procs_running"):
            run = int(line.split()[1])
        elif line.startswith("procs_blocked"):
            blk = int(line.split()[1])
    return cpu, ctxt, run, blk

prev = None
fh = open(out, "w", buffering=1)
fh.write("ts,unix,cpu_user,cpu_nice,cpu_sys,cpu_idle,cpu_iowait,cpu_irq,cpu_softirq,cpu_steal,"
         "ctxt,procs_running,procs_blocked,load1,"
         "qemu_exec_ms,qemu_rundelay_ms,qemu_slices,"
         "iperf_exec_ms,iperf_rundelay_ms,iperf_slices\n")
while True:
    t0 = time.time()
    cpu, ctxt, run, blk = procstat()
    q = schedstat_sum(qpid); i = schedstat_sum(ipid)
    load1 = open("/proc/loadavg").read().split()[0]
    if prev:
        pcpu, pctxt, pq, pi = prev
        dcpu = [a - b for a, b in zip(cpu, pcpu)]
        fh.write("%s,%d,%s,%d,%d,%d,%s,%.1f,%.1f,%d,%.1f,%.1f,%d\n" % (
            time.strftime("%Y%m%d%H%M%S", time.localtime(t0)), int(t0),
            ",".join(str(x) for x in dcpu), ctxt - pctxt, run, blk, load1,
            (q[0]-pq[0])/1e6, (q[1]-pq[1])/1e6, q[2]-pq[2],
            (i[0]-pi[0])/1e6, (i[1]-pi[1])/1e6, i[2]-pi[2]))
    prev = (cpu, ctxt, q, i)
    time.sleep(max(0.0, 1.0 - (time.time() - t0)))
