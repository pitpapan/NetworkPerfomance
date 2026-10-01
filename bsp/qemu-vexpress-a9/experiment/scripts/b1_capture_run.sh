#!/bin/bash
# b1cap.sh <run_id> <outdir> [loadgen]
source /tmp/claude-1000/-home-vboxuser-NetworkPerfomance-bsp-qemu-vexpress-a9/dff6857f-5b42-4cf4-853b-3dc89a92c2d6/scratchpad/lib.sh
S=/tmp/claude-1000/-home-vboxuser-NetworkPerfomance-bsp-qemu-vexpress-a9/dff6857f-5b42-4cf4-853b-3dc89a92c2d6/scratchpad
RID=$1; OUT=$2; LOAD=${3:-none}
QPID=$(pgrep -x qemu-system-arm | head -1)
IPID=$(pgrep -f "iperf -s -p 5001" | head -1)
tc -s qdisc show dev tap0 > "$OUT/${RID}.qdisc_pre"
python3 $S/hostmon.py "$QPID" "$IPID" "$OUT/${RID}.hostmon.csv" &
MON=$!
if [ "$LOAD" = "load" ]; then
  # deliberate contention: 2 spinners on a 2-vCPU box, started 20s in,
  # for 10s, so the window is known a priori.
  ( sleep 20; timeout 10 bash -c 'while :; do :; done' & timeout 10 bash -c 'while :; do :; done' & wait ) &
  LOADPID=$!
fi
msh "instr_tier full";     sleep 1
msh "instr_interval 100";  sleep 1
msh "instr_reset $RID";    sleep 1
msh "iperf -c 192.168.10.1 -p 5001"; sleep 92
msh "iperf --stop";        sleep 6
msh "instr_dump";          sleep 2
tmux capture-pane -p -t $TMUX_S -S -200 | tr -d '\n' | grep -o "{\"run_id\":\"$RID\".*\\}" > "$OUT/${RID}.json"
msh "instr_trace 1";       sleep 45
tmux capture-pane -p -t $TMUX_S -S -20000 \
  | sed -n "/INSTR_TRACE_BEGIN run_id=$RID/,/INSTR_TRACE_END run_id=$RID/p" > "$OUT/${RID}.trace"
kill $MON 2>/dev/null
tc -s qdisc show dev tap0 > "$OUT/${RID}.qdisc_post"
echo "$RID load=$LOAD dump=$(wc -c < "$OUT/${RID}.json") trace=$(grep -c '^[0-9]' "$OUT/${RID}.trace") mon=$(wc -l < "$OUT/${RID}.hostmon.csv")"
