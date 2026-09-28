#!/bin/bash
# Record ONE formal run's metadata as a row in experiment/results.csv.
# This does NOT drive iperf itself and does NOT loop over the matrix — it is
# invoked once per repetition, by hand, after the operator has already run
# the iperf server/client pair and read off the throughput numbers. It exists
# so qdisc counters and validity are captured consistently instead of by
# manual transcription.
#
# Usage:
#   collect_run_meta.sh <run_id> <config_id> <tcp_snd_buf> <tcp_snd_queuelen> \
#     <memp_num_tcp_seg> <configured_delay_ms> <measured_rtt_ms> <repetition_number> \
#     <total_bytes> <duration_seconds> <ubuntu_avg_mbps> [rtthread_reported_mbps] \
#     [runtime_errors] [notes]
#
# qdisc packets/dropped/overlimits/backlog are read live from `tc -s qdisc
# show dev tap0` at call time — run this immediately after the repetition,
# before the next one starts, so the counters reflect that run's window.
set -euo pipefail

BSP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS_CSV="$BSP_DIR/experiment/results.csv"

if [ "$#" -lt 11 ]; then
  echo "Usage: collect_run_meta.sh <run_id> <config_id> <tcp_snd_buf> <tcp_snd_queuelen> <memp_num_tcp_seg> <configured_delay_ms> <measured_rtt_ms> <repetition_number> <total_bytes> <duration_seconds> <ubuntu_avg_mbps> [rtthread_reported_mbps] [runtime_errors] [notes]" >&2
  exit 1
fi

RUN_ID="$1"; CONFIG_ID="$2"; SND_BUF="$3"; QUEUELEN="$4"; SEG="$5"
DELAY_MS="$6"; MEASURED_RTT="$7"; REP="$8"; BYTES="$9"; DURATION="${10}"; MBPS="${11}"
RTT_MBPS="${12:-}"; ERRORS="${13:-none}"; NOTES="${14:-}"

QSTATS="$(tc -s qdisc show dev tap0)"
PACKETS="$(echo "$QSTATS" | grep -oP '\d+(?= pkt)' | head -1 || echo "")"
DROPPED="$(echo "$QSTATS" | grep -oP 'dropped \K[0-9]+' | head -1 || echo "")"
OVERLIMITS="$(echo "$QSTATS" | grep -oP 'overlimits \K[0-9]+' | head -1 || echo "")"
BACKLOG="$(echo "$QSTATS" | grep -oP 'backlog \K[0-9a-zA-Z]+' | head -1 || echo "")"

VALID="yes"
REASON=""
if [ "${DROPPED:-0}" != "0" ]; then VALID="no"; REASON="qdisc dropped=$DROPPED"; fi
if [ "${OVERLIMITS:-0}" != "0" ]; then VALID="no"; REASON="${REASON:+$REASON; }qdisc overlimits=$OVERLIMITS"; fi
if [ "$ERRORS" != "none" ] && [ -n "$ERRORS" ]; then VALID="no"; REASON="${REASON:+$REASON; }runtime error: $ERRORS"; fi

if [ ! -f "$RESULTS_CSV" ]; then
  echo "run_id,config_id,tcp_snd_buf,tcp_snd_queuelen,memp_num_tcp_seg,configured_delay_ms,measured_rtt_ms,repetition_number,total_bytes,duration_seconds,ubuntu_avg_mbps,rtthread_reported_mbps,qdisc_packets,qdisc_dropped,qdisc_overlimits,qdisc_backlog,runtime_or_socket_errors,valid,invalid_reason,notes" > "$RESULTS_CSV"
fi

echo "$RUN_ID,$CONFIG_ID,$SND_BUF,$QUEUELEN,$SEG,$DELAY_MS,$MEASURED_RTT,$REP,$BYTES,$DURATION,$MBPS,$RTT_MBPS,$PACKETS,$DROPPED,$OVERLIMITS,$BACKLOG,$ERRORS,$VALID,$REASON,$NOTES" >> "$RESULTS_CSV"

echo "== recorded $RUN_ID ($CONFIG_ID, rep $REP, ${DELAY_MS}ms) -> valid=$VALID ${REASON:+($REASON)} =="
echo "-- appended to $RESULTS_CSV"
