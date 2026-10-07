#!/bin/bash
# Record ONE formal run as a row in experiment/results.csv, and gate its validity.
#
# Under the mechanism-attribution framing (docs/tfg_evidence/08_design_rationale.md)
# the sender's internal state IS the primary evidence, so this script records the
# instr_dump accumulators alongside throughput. A row without sender state is a
# row with no mechanism evidence, and is gated as INVALID.
#
# This does NOT drive iperf and does NOT loop over the matrix. It is invoked once
# per repetition, by hand or by an orchestration script, after the operator has
# run the iperf server/client pair and captured the instr_dump line and the
# host-side per-second CSV. It exists so qdisc counters, sender state, the N8
# per-interval gate, and validity are captured consistently instead of by manual
# transcription.
#
# RESUME SAFETY: if experiment/results/<run_id>.complete already exists, this
# script refuses to run again for that run_id (use --force to override). A run
# is marked COMPLETE only after its row is appended AND the artifact files it
# cites (--instr-json, --host-csv, if given) still exist on disk at that moment.
# COMPLETE does not mean VALID -- an INVALID run can be COMPLETE, meaning "this
# attempt is fully recorded, allocate a NEW run_id to try again" rather than
# "patch this one in place."
#
# Usage:
#   collect_run_meta.sh --run-id ID --config L0|L1|L2|STOCK|PINNED \
#       --rtt-target MS --rep N --bytes B --duration S --ubuntu-mbps M \
#       [--set main|platform|pinctl] [--measured-rtt MS] [--rtt-mbps M] \
#       [--instr-json FILE] [--host-csv FILE] [--host-conn-index N] \
#       [--boot-banner FILE] [--errors TEXT] [--notes TEXT] [--force]
#
# Configuration values are looked up from run_matrix.csv by --config, not passed
# by hand, so they cannot be mistranscribed.
#
#   --instr-json FILE    file holding the single JSON line printed by
#                        `instr_dump`. Every field instr_dump currently emits is
#                        parsed; this script does not hardcode a subset.
#   --host-csv FILE      the iperf2 `-y C` per-second CSV for this run's
#                        connection (one run's connection per file, or use
#                        --host-conn-index to select a connection within a
#                        shared file). Feeds the N8 per-interval gate
#                        (experiment/scripts/interval_gate.py) and, if --bytes/
#                        --duration/--ubuntu-mbps were not given, the
#                        throughput fields.
#   --boot-banner FILE   optional. A captured `INSTR_CFG ...` boot-banner line.
#                        If given, its TCP_SND_BUF/TCP_SND_QUEUELEN/
#                        MEMP_NUM_TCP_SEG/TCP_WND are compared against the
#                        matrix row (manifest.yaml gate: "wrong TCP
#                        configuration was compiled").
#
# qdisc counters are read live from `tc -s qdisc show dev tap0` at call time, so
# run this immediately after the repetition, before the next one starts; the
# same read also verifies the configured netem delay (manifest.yaml gate:
# "wrong netem delay was active").
#
# All numeric gate parameters below are PROPOSALS carried over from
# docs/tfg_evidence/12_phase0_measurements.md's fenced-slot table. None is
# written to manifest.yaml; they exist here so B2 (pipeline correctness) can be
# tested without waiting on that decision. Change them by editing this file,
# not by inventing a value under pressure to make a run pass.
set -euo pipefail

BSP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_CSV="$BSP_DIR/experiment/results.csv"
RESULTS_DIR="$BSP_DIR/experiment/results"
MATRIX_CSV="$BSP_DIR/experiment/run_matrix.csv"
mkdir -p "$RESULTS_DIR"

# ---- PROPOSAL gate parameters (see header) ---------------------------------
GATE_DRIFT_FRAC="${GATE_DRIFT_FRAC:-0.005}"   # PROPOSAL: >0.5% missing samples -> INVALID (12: drift tolerance row)
GATE_GAP_FACTOR="${GATE_GAP_FACTOR:-2}"       # PROPOSAL: gap_max_ticks > this x nominal -> INVALID
N8_DISCARD="${N8_DISCARD:-3}"                 # PROPOSAL, matches interval_gate.py default
N8_BIN="${N8_BIN:-5}"
N8_BAND="${N8_BAND:-0.80}"
N8_ALLOW="${N8_ALLOW:-0}"

RUN_ID=""; CONFIG=""; SET=""; RTT_TARGET=""; REP=""; BYTES=""; DURATION=""
UBUNTU_MBPS=""; MEASURED_RTT=""; RTT_MBPS=""; INSTR_JSON=""; HOST_CSV=""
HOST_CONN_INDEX="0"; BOOT_BANNER=""; ERRORS="none"; NOTES=""; FORCE="no"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id)         RUN_ID="$2"; shift 2 ;;
    --config)         CONFIG="$2"; shift 2 ;;
    --set)            SET="$2"; shift 2 ;;
    --rtt-target)     RTT_TARGET="$2"; shift 2 ;;
    --rep)            REP="$2"; shift 2 ;;
    --bytes)          BYTES="$2"; shift 2 ;;
    --duration)       DURATION="$2"; shift 2 ;;
    --ubuntu-mbps)    UBUNTU_MBPS="$2"; shift 2 ;;
    --measured-rtt)   MEASURED_RTT="$2"; shift 2 ;;
    --rtt-mbps)       RTT_MBPS="$2"; shift 2 ;;
    --instr-json)     INSTR_JSON="$2"; shift 2 ;;
    --host-csv)       HOST_CSV="$2"; shift 2 ;;
    --host-conn-index) HOST_CONN_INDEX="$2"; shift 2 ;;
    --boot-banner)    BOOT_BANNER="$2"; shift 2 ;;
    --errors)         ERRORS="$2"; shift 2 ;;
    --notes)          NOTES="$2"; shift 2 ;;
    --force)          FORCE="yes"; shift 1 ;;
    *) echo "FATAL: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

for req in RUN_ID CONFIG RTT_TARGET REP; do
  [ -n "${!req}" ] || { echo "FATAL: --${req,,} is required (see header)" >&2; exit 1; }
done

COMPLETE_MARKER="$RESULTS_DIR/${RUN_ID}.complete"
if [ -f "$COMPLETE_MARKER" ] && [ "$FORCE" != "yes" ]; then
  echo "FATAL: run_id '$RUN_ID' is already COMPLETE ($COMPLETE_MARKER)." >&2
  echo "       Allocate a new run_id to repeat the measurement, or pass --force" >&2
  echo "       to re-record under the same id (will not be done silently)." >&2
  exit 1
fi

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

VALID="yes"; REASON=""
add_reason() { VALID="no"; REASON="${REASON:+$REASON; }$1"; }

# ---- gate: wrong TCP configuration was compiled (boot banner, optional) ----
if [ -n "$BOOT_BANNER" ]; then
  [ -f "$BOOT_BANNER" ] || { echo "FATAL: --boot-banner file not found: $BOOT_BANNER" >&2; exit 1; }
  BB_LINE="$(grep -m1 '^INSTR_CFG' "$BOOT_BANNER" || true)"
  if [ -z "$BB_LINE" ]; then
    add_reason "boot banner: no INSTR_CFG line found in $BOOT_BANNER"
  else
    BB_BUF="$(echo "$BB_LINE" | grep -oP 'TCP_SND_BUF=\K[0-9]+')"
    BB_QL="$(echo "$BB_LINE" | grep -oP 'TCP_SND_QUEUELEN=\K[0-9]+')"
    BB_SEG="$(echo "$BB_LINE" | grep -oP 'MEMP_NUM_TCP_SEG=\K[0-9]+')"
    BB_WND="$(echo "$BB_LINE" | grep -oP 'TCP_WND=\K[0-9]+')"
    [ "$BB_BUF" = "$SND_BUF" ]   || add_reason "wrong TCP configuration was compiled: boot banner TCP_SND_BUF=$BB_BUF != matrix $SND_BUF"
    [ "$BB_QL"  = "$QUEUELEN" ]  || add_reason "wrong TCP configuration was compiled: boot banner TCP_SND_QUEUELEN=$BB_QL != matrix $QUEUELEN"
    [ "$BB_SEG" = "$SEG" ]       || add_reason "wrong TCP configuration was compiled: boot banner MEMP_NUM_TCP_SEG=$BB_SEG != matrix $SEG"
    [ "$BB_WND" = "$TCP_WND" ]   || add_reason "wrong TCP configuration was compiled: boot banner TCP_WND=$BB_WND != matrix $TCP_WND"
  fi
fi

# ---- sender state from instr_dump: parse EVERY field it emits -------------
# Deliberately not a fixed whitelist: the schema has grown ~13 fields in two
# sessions (B1/N8 added gap_min/max_ticks, nrtx_*, mech_*, unacked_*, etc.) and
# a hardcoded list silently drops whatever instr.c adds next. Flat (non-nested)
# scalar fields from the top-level JSON object are recorded as instr_<name>;
# the nested "cfg" and "sampler" objects are recorded with a dotted prefix.
INSTR_HEADER=""; INSTR_VALUES=""; INSTR_JSON_RUN_ID=""
INSTR_SAMPLE_COUNT=""; INSTR_STALE_COUNT=""; INSTR_GAP_MAX=""; INSTR_GAP_MIN=""
INSTR_SPAN_TICKS=""; INSTR_INTERVAL_MS=""; INSTR_TICK_PER_SEC=""
INSTR_SQ_MAX=""; INSTR_IF_MAX=""; INSTR_SW_MAX=""

if [ -n "$INSTR_JSON" ]; then
  if [ ! -f "$INSTR_JSON" ]; then
    add_reason "required output/metadata field missing: --instr-json file not found: $INSTR_JSON"
  else
    PARSE_OUT="$(python3 - "$INSTR_JSON" <<'PY' 2>&1
import json, re, sys
path = sys.argv[1]
text = open(path).read()
m = re.search(r'\{.*\}', text, re.S)
if not m:
    print("PARSE_ERROR no JSON object found in instr-json file")
    sys.exit(0)
try:
    d = json.loads(m.group(0))
except Exception as e:
    print("PARSE_ERROR could not parse instr_dump JSON: %s" % e)
    sys.exit(0)

flat = {}
for k, v in d.items():
    if isinstance(v, dict):
        for k2, v2 in v.items():
            flat["%s.%s" % (k, k2)] = v2
    else:
        flat[k] = v

names = sorted(flat.keys())
print("HEADER\t" + "\t".join(names))
print("VALUES\t" + "\t".join(str(flat[n]) for n in names))
PY
)"
    if echo "$PARSE_OUT" | grep -q '^PARSE_ERROR'; then
      add_reason "malformed instr_dump: $(echo "$PARSE_OUT" | sed 's/^PARSE_ERROR //')"
    else
      INSTR_HEADER="$(echo "$PARSE_OUT" | awk '/^HEADER\t/{sub(/^HEADER\t/,""); print}')"
      INSTR_VALUES_RAW="$(echo "$PARSE_OUT" | awk '/^VALUES\t/{sub(/^VALUES\t/,""); print}')"
      # rebuild as CSV with \t preserved field order
      IFS=$'\t' read -r -a _H <<< "$INSTR_HEADER"
      IFS=$'\t' read -r -a _V <<< "$INSTR_VALUES_RAW"
      get() { # get <field-name> -> value, "" if absent
        local name="$1" i
        for i in "${!_H[@]}"; do [ "${_H[$i]}" = "$name" ] && { echo "${_V[$i]}"; return; }; done
        echo ""
      }
      INSTR_JSON_RUN_ID="$(get run_id)"
      INSTR_SAMPLE_COUNT="$(get sample_count)"
      INSTR_STALE_COUNT="$(get stale_count)"
      INSTR_GAP_MAX="$(get gap_max_ticks)"
      INSTR_GAP_MIN="$(get gap_min_ticks)"
      INSTR_SPAN_TICKS="$(get sample_span_ticks)"
      INSTR_INTERVAL_MS="$(get sampler.interval_ms)"
      INSTR_TICK_PER_SEC="$(get sampler.tick_per_second)"
      INSTR_SQ_MAX="$(get snd_queuelen_max)"
      INSTR_IF_MAX="$(get inflight_max)"
      INSTR_SW_MAX="$(get snd_wnd_max)"
      INSTR_VALUES="$(IFS=,; echo "${_V[*]}")"

      # ---- gate: run ID mismatch between reset and dump -------------------
      if [ -n "$INSTR_JSON_RUN_ID" ] && [ "$INSTR_JSON_RUN_ID" != "$RUN_ID" ]; then
        add_reason "run_id mismatch: instr_dump run_id='$INSTR_JSON_RUN_ID' != --run-id='$RUN_ID'"
      fi

      # ---- gate: instr_sample_count == 0 -----------------------------------
      if [ "${INSTR_SAMPLE_COUNT:-0}" = "0" ]; then
        add_reason "instr sample_count=0 (sampler never fired; no mechanism evidence)"
      else
        # ---- gate: bounds violations (instrumentation fault) --------------
        if [ -n "$INSTR_SQ_MAX" ] && [ -n "$QUEUELEN" ]; then
          [ "$INSTR_SQ_MAX" -le "$QUEUELEN" ] 2>/dev/null || \
            add_reason "bounds violation: snd_queuelen_max=$INSTR_SQ_MAX > TCP_SND_QUEUELEN=$QUEUELEN"
        fi
        if [ -n "$INSTR_IF_MAX" ] && [ -n "$INSTR_SW_MAX" ] && [ "${INSTR_SW_MAX:-0}" -gt 0 ] 2>/dev/null; then
          [ "$INSTR_IF_MAX" -le "$INSTR_SW_MAX" ] 2>/dev/null || \
            add_reason "bounds violation: inflight_max=$INSTR_IF_MAX > snd_wnd_max=$INSTR_SW_MAX"
        fi

        # ---- gate: stale_count > 0 ------------------------------------
        # pcb validated against tcp_active_pcbs + port pair failed on at
        # least one timer firing (08_design_rationale.md). Structural
        # argument, never observed to fire (11 item A2) -- treated as
        # suspect rather than ignored.
        if [ -n "$INSTR_STALE_COUNT" ] && [ "${INSTR_STALE_COUNT:-0}" != "0" ] 2>/dev/null; then
          add_reason "instrumentation fault: stale_count=$INSTR_STALE_COUNT (pcb validation failed on >=1 sample)"
        fi

        # ---- gate: timing drift ----------------------------------------
        if [ -n "$INSTR_SPAN_TICKS" ] && [ -n "$INSTR_INTERVAL_MS" ] && [ -n "$INSTR_TICK_PER_SEC" ]; then
          IVAL_TICKS=$(( INSTR_INTERVAL_MS * INSTR_TICK_PER_SEC / 1000 ))
          [ "$IVAL_TICKS" -ge 1 ] || IVAL_TICKS=1
          EXPECTED=$(( INSTR_SPAN_TICKS / IVAL_TICKS + 1 ))
          if [ "$EXPECTED" -gt 0 ]; then
            DIFF=$(( EXPECTED > INSTR_SAMPLE_COUNT ? EXPECTED - INSTR_SAMPLE_COUNT : INSTR_SAMPLE_COUNT - EXPECTED ))
            # DIFF/EXPECTED > GATE_DRIFT_FRAC, done in integer-safe fixed point (x100000)
            FRAC_X100000=$(( DIFF * 100000 / EXPECTED ))
            THRESH_X100000=$(python3 -c "print(int($GATE_DRIFT_FRAC*100000))")
            if [ "$FRAC_X100000" -gt "$THRESH_X100000" ]; then
              add_reason "timing drift: sample_count=$INSTR_SAMPLE_COUNT vs expected=$EXPECTED (span=$INSTR_SPAN_TICKS ticks, interval=$IVAL_TICKS ticks) differ by ${FRAC_X100000}e-5 > ${GATE_DRIFT_FRAC} threshold"
            fi
          fi
          if [ -n "$INSTR_GAP_MAX" ]; then
            GAP_THRESH=$(( IVAL_TICKS * GATE_GAP_FACTOR ))
            if [ "$INSTR_GAP_MAX" -gt "$GAP_THRESH" ] 2>/dev/null; then
              add_reason "timing drift: gap_max_ticks=$INSTR_GAP_MAX > ${GATE_GAP_FACTOR}x nominal interval ($IVAL_TICKS ticks)"
            fi
          fi
        fi
      fi
    fi
  fi
else
  add_reason "required output/metadata field missing: no instr_dump captured (no mechanism evidence)"
fi

# ---- host-side per-second CSV: throughput fallback + N8 gate --------------
N8_VERDICT=""; N8_REASON=""
if [ -n "$HOST_CSV" ]; then
  if [ ! -f "$HOST_CSV" ]; then
    add_reason "required output/metadata field missing: --host-csv file not found: $HOST_CSV"
  else
    N8_OUT="$(python3 "$SCRIPT_DIR/interval_gate.py" check "$HOST_CSV" "$HOST_CONN_INDEX" \
                --discard "$N8_DISCARD" --bin "$N8_BIN" --band "$N8_BAND" --allow "$N8_ALLOW" 2>&1)" \
      || true
      N8_VERDICT="$(echo "$N8_OUT" | awk '{print $1; exit}')"
      N8_REASON="$(echo "$N8_OUT" | cut -d' ' -f2-)"
    case "$N8_VERDICT" in
      INVALID)      add_reason "N8 per-interval gate: $N8_REASON" ;;
      INSUFFICIENT) add_reason "N8 per-interval gate could not evaluate: $N8_REASON" ;;
      VALID) : ;;
      *) add_reason "N8 per-interval gate: unexpected output: $N8_OUT" ;;
    esac
  fi
else
  add_reason "required output/metadata field missing: no host-side per-second CSV provided (N8 gate cannot run)"
fi

# ---- gate: wrong netem delay was active ------------------------------------
if command -v tc >/dev/null 2>&1 && ip link show tap0 >/dev/null 2>&1; then
  QLINE="$(tc qdisc show dev tap0 2>/dev/null || true)"
  if [ -n "$QLINE" ]; then
    if ! echo "$QLINE" | grep -q "delay ${RTT_TARGET}ms"; then
      add_reason "wrong netem delay was active: tap0 qdisc is '$QLINE', expected delay ${RTT_TARGET}ms"
    fi
  fi
fi

# ---- live qdisc counters (another benchmark instance / drops) -------------
QSTATS="$(tc -s qdisc show dev tap0 2>/dev/null || true)"
PACKETS="$(echo "$QSTATS" | grep -oP '\d+(?= pkt)' | head -1 || echo "")"
DROPPED="$(echo "$QSTATS" | grep -oP 'dropped \K[0-9]+' | head -1 || echo "")"
OVERLIMITS="$(echo "$QSTATS" | grep -oP 'overlimits \K[0-9]+' | head -1 || echo "")"
BACKLOG="$(echo "$QSTATS" | grep -oP 'backlog \K[0-9a-zA-Z]+' | head -1 || echo "")"

[ "${DROPPED:-0}" = "0" ]    || add_reason "qdisc dropped=$DROPPED due to netem queue exhaustion"
[ "${OVERLIMITS:-0}" = "0" ] || add_reason "qdisc overlimits=$OVERLIMITS"
if [ "$ERRORS" != "none" ] && [ -n "$ERRORS" ]; then add_reason "iperf connection terminated abnormally: $ERRORS"; fi

# ---- throughput fallback from host CSV if not hand-given -------------------
if [ -z "$BYTES$DURATION$UBUNTU_MBPS" ] && [ -n "$HOST_CSV" ] && [ -f "$HOST_CSV" ]; then
  read -r BYTES DURATION UBUNTU_MBPS <<<"$(python3 - "$HOST_CSV" "$HOST_CONN_INDEX" <<'PY'
import sys
path, idx = sys.argv[1], int(sys.argv[2])
conns = {}
order = []
for line in open(path):
    f = line.strip().split(',')
    if len(f) < 9: continue
    try:
        by = int(f[7]); bps = int(f[8])
        a, b = [float(x) for x in f[6].split('-')]
    except ValueError:
        continue
    if f[2] not in conns:
        order.append(f[2])
    conns[f[2]] = (by, b - a, bps / 1e6)  # last (summary) row wins
if idx < len(order):
    by, dur, mbps = conns[order[idx]]
    print(by, "%.3f" % dur, "%.4f" % mbps)
else:
    print(0, 0, 0)
PY
)"
fi
for req in BYTES DURATION UBUNTU_MBPS; do
  [ -n "${!req}" ] || { echo "FATAL: --${req,,} is required, and no --host-csv fallback was usable (see header)" >&2; exit 1; }
done

# ---- append ----------------------------------------------------------------
if [ ! -f "$RESULTS_CSV" ]; then
  {
    printf 'run_id,cell_id,set,config_id,tcp_snd_buf,tcp_snd_queuelen,memp_num_tcp_seg,tcp_wnd,'
    printf 'configured_delay_ms,measured_rtt_ms,repetition_number,'
    printf 'total_bytes,duration_seconds,ubuntu_avg_mbps,rtthread_reported_mbps,'
    printf 'n8_verdict,'
    printf 'qdisc_packets,qdisc_dropped,qdisc_overlimits,qdisc_backlog,'
    printf 'runtime_or_socket_errors,valid,invalid_reason,notes,instr_fields\n'
  } > "$RESULTS_CSV"
fi

# instr_fields: self-describing "name=value;name=value" blob, since the
# schema is not fixed (see note above INSTR_HEADER). Keeps results.csv
# readable even as instr.c grows more fields, without a header migration.
INSTR_BLOB=""
if [ -n "$INSTR_HEADER" ]; then
  IFS=$'\t' read -r -a _H2 <<< "$INSTR_HEADER"
  IFS=,     read -r -a _V2 <<< "$INSTR_VALUES"
  for i in "${!_H2[@]}"; do INSTR_BLOB="${INSTR_BLOB}${_H2[$i]}=${_V2[$i]};"; done
fi

# CSV-escape fields that may contain ',' or ';' (REASON, NOTES, INSTR_BLOB)
csvq() { printf '"%s"' "$(echo -n "$1" | sed 's/"/""/g')"; }

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$RUN_ID" "$CELL_ID" "$SET" "$CONFIG" "$SND_BUF" "$QUEUELEN" "$SEG" "$TCP_WND" \
  "$RTT_TARGET" "$MEASURED_RTT" "$REP" \
  "$BYTES" "$DURATION" "$UBUNTU_MBPS" "$RTT_MBPS" \
  "${N8_VERDICT:-not_run}" \
  "$PACKETS" "$DROPPED" "$OVERLIMITS" "$BACKLOG" \
  "$ERRORS" "$VALID" "$(csvq "$REASON")" "$(csvq "$NOTES")" "$(csvq "$INSTR_BLOB")" >> "$RESULTS_CSV"

echo "== recorded $RUN_ID ($CELL_ID, $CONFIG, rep $REP, ${RTT_TARGET}ms) -> valid=$VALID ${REASON:+($REASON)} =="
echo "-- appended to $RESULTS_CSV"

# ---- COMPLETE marker: only after the row is written AND cited artifacts ---
# still exist on disk right now. Does not depend on VALID.
ARTIFACTS_OK="yes"
[ -n "$INSTR_JSON" ] && [ ! -f "$INSTR_JSON" ] && ARTIFACTS_OK="no"
[ -n "$HOST_CSV" ]   && [ ! -f "$HOST_CSV" ]   && ARTIFACTS_OK="no"
[ -n "$BOOT_BANNER" ] && [ ! -f "$BOOT_BANNER" ] && ARTIFACTS_OK="no"

if [ "$ARTIFACTS_OK" = "yes" ]; then
  {
    echo "run_id=$RUN_ID"
    echo "recorded_utc=$(date -u +%Y%m%dT%H%M%SZ)"
    echo "valid=$VALID"
    echo "instr_json=${INSTR_JSON:-none}"
    echo "host_csv=${HOST_CSV:-none}"
  } > "$COMPLETE_MARKER"
  echo "-- marked COMPLETE: $COMPLETE_MARKER"
else
  echo "-- NOT marked COMPLETE: a cited artifact file is missing (row was still written above)"
fi
