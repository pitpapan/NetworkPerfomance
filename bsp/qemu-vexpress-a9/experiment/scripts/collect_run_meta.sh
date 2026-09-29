#!/bin/bash
# Record ONE formal run as a row in experiment/results.csv.
#
# Under the mechanism-attribution framing (docs/tfg_evidence/08_design_rationale.md)
# the sender's internal state IS the primary evidence, so this script records the
# instr_dump accumulators alongside throughput. A row without sender state is a
# row with no mechanism evidence, and is gated as INVALID.
#
# This does NOT drive iperf and does NOT loop over the matrix. It is invoked once
# per repetition, by hand, after the operator has run the iperf server/client pair
# and captured the instr_dump line. It exists so qdisc counters, sender state and
# validity are captured consistently instead of by manual transcription.
#
# Usage:
#   collect_run_meta.sh --run-id ID --config L0|L1|L2|STOCK|PINNED \
#       --rtt-target MS --rep N --bytes B --duration S --ubuntu-mbps M \
#       [--set main|platform|pinctl] [--measured-rtt MS] [--rtt-mbps M] \
#       [--instr-json FILE] [--errors TEXT] [--notes TEXT]
#
# Configuration values are looked up from run_matrix.csv by --config, not passed
# by hand, so they cannot be mistranscribed. --instr-json takes the file holding
# the single JSON line printed by `instr_dump`.
#
# qdisc counters are read live from `tc -s qdisc show dev tap0` at call time, so
# run this immediately after the repetition, before the next one starts.
set -euo pipefail

BSP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS_CSV="$BSP_DIR/experiment/results.csv"
MATRIX_CSV="$BSP_DIR/experiment/run_matrix.csv"

RUN_ID=""; CONFIG=""; SET=""; RTT_TARGET=""; REP=""; BYTES=""; DURATION=""
UBUNTU_MBPS=""; MEASURED_RTT=""; RTT_MBPS=""; INSTR_JSON=""; ERRORS="none"; NOTES=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id)       RUN_ID="$2"; shift 2 ;;
    --config)       CONFIG="$2"; shift 2 ;;
    --set)          SET="$2"; shift 2 ;;
    --rtt-target)   RTT_TARGET="$2"; shift 2 ;;
    --rep)          REP="$2"; shift 2 ;;
    --bytes)        BYTES="$2"; shift 2 ;;
    --duration)     DURATION="$2"; shift 2 ;;
    --ubuntu-mbps)  UBUNTU_MBPS="$2"; shift 2 ;;
    --measured-rtt) MEASURED_RTT="$2"; shift 2 ;;
    --rtt-mbps)     RTT_MBPS="$2"; shift 2 ;;
    --instr-json)   INSTR_JSON="$2"; shift 2 ;;
    --errors)       ERRORS="$2"; shift 2 ;;
    --notes)        NOTES="$2"; shift 2 ;;
    *) echo "FATAL: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

for req in RUN_ID CONFIG RTT_TARGET REP BYTES DURATION UBUNTU_MBPS; do
  [ -n "${!req}" ] || { echo "FATAL: --${req,,} is required (see header)" >&2; exit 1; }
done

# ---- configuration looked up from the matrix, never hand-typed --------------
ROW="$(awk -F, -v c="$CONFIG" -v r="$RTT_TARGET" \
        '$3==c && $7==r {print; exit}' "$MATRIX_CSV" || true)"
if [ -z "$ROW" ]; then
  echo "FATAL: no cell in run_matrix.csv for config='$CONFIG' rtt_ms='$RTT_TARGET'" >&2
  exit 1
fi
CELL_ID="$(echo "$ROW" | cut -d, -f1)"
MATRIX_SET="$(echo "$ROW" | cut -d, -f2)"
SND_BUF="$(echo "$ROW" | cut -d, -f4)"
QUEUELEN="$(echo "$ROW" | cut -d, -f5)"
SEG="$(echo "$ROW" | cut -d, -f6)"
SET="${SET:-$MATRIX_SET}"

# TCP_WND is pinned by set_config.sh; record what the tree actually says.
TCP_WND="$(grep -oP '^#define RT_LWIP_TCP_WND \K[0-9]+' "$BSP_DIR/rtconfig.h")"

# ---- sender state from instr_dump ------------------------------------------
INSTR_FIELDS=(sample_count snd_buf_min snd_buf_low_count snd_queuelen_max \
              cwnd_min cwnd_max cwnd_mean_x1000 \
              snd_wnd_min snd_wnd_max snd_wnd_mean_x1000 \
              inflight_min inflight_max inflight_mean_x1000 \
              unsent_nonempty_count unsent_bytes_max)

INSTR_VALUES=""
INSTR_SAMPLE_COUNT=""
if [ -n "$INSTR_JSON" ]; then
  [ -f "$INSTR_JSON" ] || { echo "FATAL: --instr-json file not found: $INSTR_JSON" >&2; exit 1; }
  INSTR_VALUES="$(python3 - "$INSTR_JSON" "${INSTR_FIELDS[@]}" <<'PY'
import json, re, sys
path, fields = sys.argv[1], sys.argv[2:]
text = open(path).read()
m = re.search(r'\{.*\}', text, re.S)
if not m:
    sys.stderr.write("FATAL: no JSON object found in %s\n" % path); sys.exit(1)
try:
    d = json.loads(m.group(0))
except Exception as e:
    sys.stderr.write("FATAL: could not parse instr_dump JSON: %s\n" % e); sys.exit(1)
missing = [f for f in fields if f not in d]
if missing:
    sys.stderr.write("FATAL: instr_dump JSON missing fields: %s\n" % ",".join(missing)); sys.exit(1)
print(",".join(str(d[f]) for f in fields))
PY
)" || exit 1
  INSTR_SAMPLE_COUNT="$(echo "$INSTR_VALUES" | cut -d, -f1)"
else
  # keep column count stable
  INSTR_VALUES="$(printf ',%.0s' $(seq 1 $(( ${#INSTR_FIELDS[@]} - 1 ))))"
fi

# ---- live qdisc counters ----------------------------------------------------
QSTATS="$(tc -s qdisc show dev tap0)"
PACKETS="$(echo "$QSTATS" | grep -oP '\d+(?= pkt)' | head -1 || echo "")"
DROPPED="$(echo "$QSTATS" | grep -oP 'dropped \K[0-9]+' | head -1 || echo "")"
OVERLIMITS="$(echo "$QSTATS" | grep -oP 'overlimits \K[0-9]+' | head -1 || echo "")"
BACKLOG="$(echo "$QSTATS" | grep -oP 'backlog \K[0-9a-zA-Z]+' | head -1 || echo "")"

# ---- validity gates --------------------------------------------------------
VALID="yes"; REASON=""
add_reason() { VALID="no"; REASON="${REASON:+$REASON; }$1"; }

[ "${DROPPED:-0}" = "0" ]    || add_reason "qdisc dropped=$DROPPED"
[ "${OVERLIMITS:-0}" = "0" ] || add_reason "qdisc overlimits=$OVERLIMITS"
if [ "$ERRORS" != "none" ] && [ -n "$ERRORS" ]; then add_reason "runtime error: $ERRORS"; fi

if [ -z "$INSTR_JSON" ]; then
  add_reason "no instr_dump captured (no mechanism evidence)"
elif [ "${INSTR_SAMPLE_COUNT:-0}" = "0" ]; then
  add_reason "instr sample_count=0 (sampler never fired; no mechanism evidence)"
else
  SQ_MAX="$(echo "$INSTR_VALUES" | cut -d, -f4)"
  IF_MAX="$(echo "$INSTR_VALUES" | cut -d, -f12)"
  SW_MAX="$(echo "$INSTR_VALUES" | cut -d, -f9)"
  [ "$SQ_MAX" -le "$QUEUELEN" ] 2>/dev/null || \
    add_reason "bounds violation: snd_queuelen_max=$SQ_MAX > TCP_SND_QUEUELEN=$QUEUELEN"
  if [ -n "$IF_MAX" ] && [ -n "$SW_MAX" ] && [ "$SW_MAX" -gt 0 ] 2>/dev/null; then
    [ "$IF_MAX" -le "$SW_MAX" ] 2>/dev/null || \
      add_reason "bounds violation: inflight_max=$IF_MAX > snd_wnd_max=$SW_MAX"
  fi
fi

# ---- append ----------------------------------------------------------------
if [ ! -f "$RESULTS_CSV" ]; then
  {
    printf 'run_id,cell_id,set,config_id,tcp_snd_buf,tcp_snd_queuelen,memp_num_tcp_seg,tcp_wnd,'
    printf 'configured_delay_ms,measured_rtt_ms,repetition_number,'
    printf 'total_bytes,duration_seconds,ubuntu_avg_mbps,rtthread_reported_mbps,'
    for f in "${INSTR_FIELDS[@]}"; do printf 'instr_%s,' "$f"; done
    printf 'qdisc_packets,qdisc_dropped,qdisc_overlimits,qdisc_backlog,'
    printf 'runtime_or_socket_errors,valid,invalid_reason,notes\n'
  } > "$RESULTS_CSV"
fi

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$RUN_ID" "$CELL_ID" "$SET" "$CONFIG" "$SND_BUF" "$QUEUELEN" "$SEG" "$TCP_WND" \
  "$RTT_TARGET" "$MEASURED_RTT" "$REP" \
  "$BYTES" "$DURATION" "$UBUNTU_MBPS" "$RTT_MBPS" \
  "$INSTR_VALUES" \
  "$PACKETS" "$DROPPED" "$OVERLIMITS" "$BACKLOG" \
  "$ERRORS" "$VALID" "$REASON" "$NOTES" >> "$RESULTS_CSV"

echo "== recorded $RUN_ID ($CELL_ID, $CONFIG, rep $REP, ${RTT_TARGET}ms) -> valid=$VALID ${REASON:+($REASON)} =="
echo "-- appended to $RESULTS_CSV"
