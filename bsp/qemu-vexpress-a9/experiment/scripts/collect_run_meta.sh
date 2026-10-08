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
# cites (--instr-json, --host-csv, --boot-banner, --trace, if given) still
# exist on disk at that moment.
# COMPLETE does not mean VALID -- an INVALID run can be COMPLETE, meaning "this
# attempt is fully recorded, allocate a NEW run_id to try again" rather than
# "patch this one in place."
#
# VALIDITY SEMANTICS CHANGE (2026-10-08, implements the N8/scientific-validity
# distinction drafted and PASS-WITH-QUALIFICATION-audited in
# docs/tfg_evidence/11_open_problems.md N8, and corrected in
# docs/tfg_evidence/13_pilot_20ms.md's audit-corrections section):
#
# PREVIOUSLY, any N8 (experiment/scripts/interval_gate.py) flag at all --
# INVALID (collapse pattern) or INSUFFICIENT (any reason) -- unconditionally
# forced this script's `valid` column to `no`, exactly like every other gate.
# This conflated "a specific, pre-specified protocol/measurement failure
# occurred" with "the detector flagged an unusual-but-real throughput
# pattern on an otherwise complete, correctly-identified run."
#
# NOW, a new `VALIDITY_CLASS` is computed, with three values:
#   - VALID_NORMAL:    no gate of any kind fired.
#   - VALID_ANOMALOUS: every independently-justified gate passed (wrong
#                       config, wrong netem delay, qdisc drops, stale pcb,
#                       timing drift, zero samples, run_id mismatch, runtime/
#                       socket error, missing required file/field) AND the
#                       only thing that fired is N8 reporting INVALID (a
#                       throughput-collapse *pattern*, which may be real and
#                       is retained, not excluded) or N8 reporting
#                       INSUFFICIENT specifically because "run median is
#                       zero" (a real, complete, degenerate observation --
#                       not missing data).
#   - INVALID:         any independently-justified gate above fires, OR N8
#                       reports INSUFFICIENT for any OTHER reason: "fewer
#                       than N intervals after the discard window" (a
#                       genuine data-completeness failure) or "no connection
#                       at index N" (a connection-identity failure) each
#                       route to INVALID with their own specific named
#                       reason, not lumped with the median-zero case.
#
# The pre-existing `valid` column is RETAINED as a compatibility field,
# redefined precisely as: `yes` when VALIDITY_CLASS is VALID_NORMAL or
# VALID_ANOMALOUS; `no` when VALIDITY_CLASS is INVALID. This is a REAL
# BEHAVIOR CHANGE from before (previously ANY N8 flag forced valid=no; now
# only the data-completeness/connection-identity N8 sub-cases do) -- flagged
# here prominently because, although there are currently zero real
# consumers of results.csv (it has never been produced by a real formal
# run), a future reader must not assume `valid` means what it meant before
# this change.
#
# Three new CSV columns record the underlying N8 diagnostic independent of
# the classification it produced: `n8_reason` (the full N8 reason text,
# populated whenever N8 ran, regardless of verdict/classification),
# `validity_class` (the three-way value above), and `anomaly_reason` (the
# N8-anomaly text specifically when VALIDITY_CLASS=VALID_ANOMALOUS, empty
# otherwise). `invalid_reason` keeps its prior meaning unchanged: only
# INVALID-causing reasons (it is still fed exclusively by `add_reason`).
#
# No other gate's behavior changes. GATE_DRIFT_FRAC/GATE_GAP_FACTOR/
# DISCARD_INTERVAL_S (named N8_DISCARD before the 2026-10-08 trace-windowing
# integration, below)/N8_BIN/N8_BAND/N8_ALLOW are untouched -- this is a
# classification change, not a detector-sensitivity change.
#
# Usage:
#   collect_run_meta.sh --run-id ID --config L0|L1|L2|STOCK|PINNED \
#       --rtt-target MS --rep N --bytes B --duration S --ubuntu-mbps M \
#       [--set main|platform|pinctl] [--measured-rtt MS] [--rtt-mbps M] \
#       [--instr-json FILE] [--host-csv FILE] [--host-conn-index N] \
#       [--boot-banner FILE] [--trace FILE] [--errors TEXT] [--notes TEXT] [--force]
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
#   --trace FILE         the `instr_trace` per-sample trace file (same format
#                        as every docs/tfg_evidence/raw_logs/*/*.trace: an
#                        INSTR_TRACE_BEGIN/header/data-rows/INSTR_TRACE_END
#                        block). Required (when --instr-json parsed with a
#                        non-zero sample_count) to compute the discard-
#                        windowed `window_mech_*` PRIMARY mechanism evidence
#                        via experiment/scripts/compute_discard_windowed_mechfrac.py
#                        -- see the "PRIMARY VS. DIAGNOSTIC" note above. If
#                        omitted, or if the gates below (G1-G6) fail, the row
#                        is INVALID for missing primary evidence and the
#                        `window_*` columns are left empty (not zero).
#
# qdisc counters are read live from `tc -s qdisc show dev tap0` at call time, so
# run this immediately after the repetition, before the next one starts; the
# same read also verifies the configured netem delay (manifest.yaml gate:
# "wrong netem delay was active").
#
# Numeric gate parameters below, status as of 2026-10-08 (manifest.yaml
# tbd_from_pilot is now frozen -- see that file):
#   GATE_DRIFT_FRAC, GATE_GAP_FACTOR: still PROPOSALS. Never part of the
#     tbd_from_pilot bundle; not re-examined by the 2026-10-08 freeze task.
#   DISCARD_INTERVAL_S: FROZEN -- this IS manifest.yaml's
#     tbd_from_pilot.discard_interval_s (=3). Feeds BOTH N8's own
#     `--discard` argument (unchanged behavior, was N8_DISCARD before
#     2026-10-08's trace-windowing integration -- renamed, not
#     reintroduced, to make explicit that it is one protocol-level value,
#     not an N8-specific tuning knob) AND the discard-windowed primary-
#     evidence step's `--discard` argument below. If that value is ever
#     re-frozen, update this default to match; do not let the two drift
#     apart silently, and do not invent a second, conflicting default
#     anywhere else in this file.
#   RUN_DURATION_S: FROZEN -- this IS manifest.yaml's
#     tbd_from_pilot.run_duration_s (=60). Feeds the discard-windowed
#     primary-evidence step's `--duration` argument. Same re-freeze
#     warning as DISCARD_INTERVAL_S above.
#   N8_BIN, N8_BAND, N8_ALLOW: documented diagnostic settings (not frozen
#     protocol parameters -- never part of the tbd_from_pilot bundle,
#     explicitly not re-tuned by the 2026-10-08 task, which authorized a
#     classification change, not a detector-sensitivity change). See
#     docs/tfg_evidence/11_open_problems.md N8/N16 for their evidentiary
#     basis and known margin limits.
# Change any of these by editing this file, not by inventing a value under
# pressure to make a run pass.
#
# PRIMARY VS. DIAGNOSTIC MECHANISM EVIDENCE (2026-10-08, trace-windowing
# integration): `instr_mech_*` (inside the `instr_fields` blob below) is
# the WHOLE-RUN diagnostic count, computed by instr.c's own accumulators
# from `instr_reset` to `instr_dump` with no discard applied -- it cannot
# retroactively exclude the first DISCARD_INTERVAL_S seconds. The new
# `window_mech_*` columns are the discard-windowed PRIMARY evidence,
# computed from the per-sample trace (--trace) by
# experiment/scripts/compute_discard_windowed_mechfrac.py, reproducing
# exactly the method already used throughout
# docs/tfg_evidence/13_pilot_20ms.md. The two are expected to differ, most
# visibly for a run with a startup burst or an overrun tail (see
# pilot20_L0_r50_1: whole-run 3.117%, windowed 3.228%, at completely
# different sample counts, 4395 vs 2850).
set -euo pipefail

BSP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_CSV="$BSP_DIR/experiment/results.csv"
RESULTS_DIR="$BSP_DIR/experiment/results"
MATRIX_CSV="$BSP_DIR/experiment/run_matrix.csv"
mkdir -p "$RESULTS_DIR"

# ---- gate parameters (see header for FROZEN/PROPOSAL/diagnostic status) ---
GATE_DRIFT_FRAC="${GATE_DRIFT_FRAC:-0.005}"   # PROPOSAL: >0.5% missing samples -> INVALID (12: drift tolerance row)
GATE_GAP_FACTOR="${GATE_GAP_FACTOR:-2}"       # PROPOSAL: gap_max_ticks > this x nominal -> INVALID
DISCARD_INTERVAL_S="${DISCARD_INTERVAL_S:-3}" # FROZEN 2026-10-08 == tbd_from_pilot.discard_interval_s
                                               # (was N8_DISCARD; renamed -- feeds N8 AND the windowing step)
RUN_DURATION_S="${RUN_DURATION_S:-60}"        # FROZEN 2026-10-08 == tbd_from_pilot.run_duration_s
N8_BIN="${N8_BIN:-5}"                         # documented diagnostic setting, not frozen
N8_BAND="${N8_BAND:-0.80}"                    # documented diagnostic setting, not frozen
N8_ALLOW="${N8_ALLOW:-0}"                     # documented diagnostic setting, not frozen

RUN_ID=""; CONFIG=""; SET=""; RTT_TARGET=""; REP=""; BYTES=""; DURATION=""
UBUNTU_MBPS=""; MEASURED_RTT=""; RTT_MBPS=""; INSTR_JSON=""; HOST_CSV=""; TRACE=""
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
    --trace)          TRACE="$2"; shift 2 ;;
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
# Set to "yes" only in the success path below (instr_dump parsed AND
# sample_count != 0) -- tracked explicitly so the windowing section below
# does not re-derive "did instr_dump parse ok" by re-checking variables
# that could be stale from an earlier gate.
INSTR_JSON_OK="no"

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
        INSTR_JSON_OK="yes"
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

# ---- primary evidence: discard-windowed mech_* fractions from the trace ---
# Gated on instr_dump having actually parsed AND had a non-zero sample
# count (INSTR_JSON_OK, set above) -- if instr_dump itself failed, that
# row is already headed to INVALID for missing mechanism evidence, and a
# second "missing trace" reason on top would just be confusing.
#
# G1-G6 below are independently named so invalid_reason stays traceable;
# see this script's own header and docs/tfg_evidence/11_open_problems.md
# N8 for the broader design. compute_discard_windowed_mechfrac.py is the
# sole implementation of the windowing algorithm -- this section only
# invokes it and gates on its output, it does not reimplement any part of
# the per-sample classification or window arithmetic.
WINDOW_DISCARD_S=""; WINDOW_DURATION_S=""; WINDOW_SAMPLE_COUNT=""
WINDOW_APP=""; WINDOW_UNSENT=""; WINDOW_ACK=""
WINDOW_APP_PCT=""; WINDOW_UNSENT_PCT=""; WINDOW_ACK_PCT=""
if [ "$INSTR_JSON_OK" = "yes" ]; then
  if [ -z "$TRACE" ]; then
    # G1
    add_reason "required output/metadata field missing: --trace not provided (required for primary discard-windowed mechanism evidence)"
  elif [ ! -f "$TRACE" ]; then
    # G2
    add_reason "required output/metadata field missing: --trace file not found: $TRACE"
  elif ! grep -q '^INSTR_TRACE_BEGIN' "$TRACE"; then
    # G3a
    add_reason "malformed trace: no INSTR_TRACE_BEGIN marker found in $TRACE"
  else
    TRACE_RUN_ID="$(grep -m1 '^INSTR_TRACE_BEGIN' "$TRACE" | grep -oP 'run_id=\K\S+' || true)"
    if [ "$TRACE_RUN_ID" != "$RUN_ID" ]; then
      # G3b (distinct wording from the instr_dump run_id-mismatch gate above)
      add_reason "run_id mismatch: trace run_id='$TRACE_RUN_ID' != --run-id='$RUN_ID'"
    else
      # G4: invoke the standalone windowing script. Capture stdout/stderr
      # separately -- the script's own documented behavior prints a
      # WARNING to stderr (not a failure) when the window is empty (G5),
      # and mixing that into stdout would break JSON parsing below.
      WINDOW_ERRFILE="$(mktemp)"
      WINDOW_RC=0
      WINDOW_OUT="$(python3 "$SCRIPT_DIR/compute_discard_windowed_mechfrac.py" \
                      "$INSTR_JSON" "$TRACE" \
                      --discard "$DISCARD_INTERVAL_S" --duration "$RUN_DURATION_S" \
                      2>"$WINDOW_ERRFILE")" || WINDOW_RC=$?
      WINDOW_ERR="$(cat "$WINDOW_ERRFILE" 2>/dev/null || true)"
      rm -f "$WINDOW_ERRFILE"

      if [ "$WINDOW_RC" -ne 0 ]; then
        add_reason "primary evidence windowing failed: $WINDOW_ERR$WINDOW_OUT"
      else
        WINDOW_PARSE_RC=0
        WINDOW_PARSE="$(python3 - "$WINDOW_OUT" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    j = json.loads(raw)
except Exception as e:
    print("PARSE_ERROR\t%s" % e)
    sys.exit(0)
w = j.get("windowed")
tc = j.get("trace_complete")
tr = j.get("trace_rows_read")
sc = j.get("instr_dump_sample_count")
if w is None:
    print("NULL\t%s\t%s\t%s" % (tc, tr, sc))
else:
    print("WIN\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%.3f\t%.3f\t%.3f" % (
        tc, tr, sc,
        w["n"], w["counts"]["app_limited"], w["counts"]["unsent_pending"], w["counts"]["ack_pending"],
        w["fraction_pct"]["app_limited"], w["fraction_pct"]["unsent_pending"], w["fraction_pct"]["ack_pending"]))
PY
)" || WINDOW_PARSE_RC=$?
        WINDOW_KIND="$(echo "$WINDOW_PARSE" | cut -f1)"
        if [ "$WINDOW_PARSE_RC" -ne 0 ] || [ "$WINDOW_KIND" = "PARSE_ERROR" ]; then
          add_reason "primary evidence windowing failed: $WINDOW_ERR$WINDOW_OUT"
        elif [ "$WINDOW_KIND" = "NULL" ]; then
          # G5: documented null-window case (zero samples fall in the window)
          add_reason "required output/metadata field missing: zero samples in discard-window [${DISCARD_INTERVAL_S},${RUN_DURATION_S})s -- primary mechanism evidence unavailable"
          WTC="$(echo "$WINDOW_PARSE" | cut -f2)"
          WTR="$(echo "$WINDOW_PARSE" | cut -f3)"
          WSC="$(echo "$WINDOW_PARSE" | cut -f4)"
          if [ "$WTC" != "True" ]; then
            # G6, independent of G5 -- both may fire on the same run
            add_reason "trace incomplete: trace_rows_read=$WTR != instr_dump sample_count=$WSC (possible trace-ring wrap or truncated capture)"
          fi
        else
          WTC="$(echo "$WINDOW_PARSE" | cut -f2)"
          WTR="$(echo "$WINDOW_PARSE" | cut -f3)"
          WSC="$(echo "$WINDOW_PARSE" | cut -f4)"
          if [ "$WTC" != "True" ]; then
            # G6
            add_reason "trace incomplete: trace_rows_read=$WTR != instr_dump sample_count=$WSC (possible trace-ring wrap or truncated capture)"
          else
            # G1-G6 all passed: extract and keep the primary evidence.
            WINDOW_DISCARD_S="$DISCARD_INTERVAL_S"
            WINDOW_DURATION_S="$RUN_DURATION_S"
            WINDOW_SAMPLE_COUNT="$(echo "$WINDOW_PARSE" | cut -f5)"
            WINDOW_APP="$(echo "$WINDOW_PARSE" | cut -f6)"
            WINDOW_UNSENT="$(echo "$WINDOW_PARSE" | cut -f7)"
            WINDOW_ACK="$(echo "$WINDOW_PARSE" | cut -f8)"
            WINDOW_APP_PCT="$(echo "$WINDOW_PARSE" | cut -f9)"
            WINDOW_UNSENT_PCT="$(echo "$WINDOW_PARSE" | cut -f10)"
            WINDOW_ACK_PCT="$(echo "$WINDOW_PARSE" | cut -f11)"
          fi
        fi
      fi
    fi
  fi
fi

# ---- host-side per-second CSV: throughput fallback + N8 gate --------------
# N8_ANOMALY_REASON (distinct from REASON/add_reason): set only for the two
# N8 outcomes that are an anomalous-but-complete OBSERVATION rather than a
# protocol/measurement failure -- INVALID (collapse pattern) and
# INSUFFICIENT/"run median is zero" (degenerate but complete). These do NOT
# call add_reason and so do NOT force VALID=no. Every OTHER N8 outcome that
# is not plain VALID is a genuine protocol/measurement failure and still
# calls add_reason with its own specific, named reason (see header comment).
N8_VERDICT=""; N8_REASON=""; N8_ANOMALY_REASON=""
if [ -n "$HOST_CSV" ]; then
  if [ ! -f "$HOST_CSV" ]; then
    add_reason "required output/metadata field missing: --host-csv file not found: $HOST_CSV"
  else
    N8_OUT="$(python3 "$SCRIPT_DIR/interval_gate.py" check "$HOST_CSV" "$HOST_CONN_INDEX" \
                --discard "$DISCARD_INTERVAL_S" --bin "$N8_BIN" --band "$N8_BAND" --allow "$N8_ALLOW" 2>&1)" \
      || true
      N8_VERDICT="$(echo "$N8_OUT" | awk '{print $1; exit}')"
      N8_REASON="$(echo "$N8_OUT" | cut -d' ' -f2-)"
    case "$N8_VERDICT" in
      INVALID)
        # A throughput-collapse pattern -- real and retained, not a gate
        # failure, per 13_pilot_20ms.md's "N8 kept separate from pilot
        # classification" policy and 11's N8 entry.
        N8_ANOMALY_REASON="N8 per-interval gate (collapse pattern, retained not excluded): $N8_REASON"
        ;;
      INSUFFICIENT)
        case "$N8_REASON" in
          *"run median is zero"*)
            # Real, complete, degenerate observation -- not missing data.
            N8_ANOMALY_REASON="N8 per-interval gate (insufficient: run median is zero -- complete degenerate observation, retained not excluded): $N8_REASON"
            ;;
          *"no connection at index"*)
            # Connection-identity failure (main()'s own out-of-range
            # --host-conn-index case) -- a genuine protocol/measurement
            # failure, not an anomalous-but-complete observation.
            add_reason "N8 gate: connection index out of range: $N8_REASON"
            ;;
          *"fewer than"*"intervals after"*)
            # Genuine data-completeness failure (gate()'s own 2-bin minimum).
            add_reason "N8 gate: insufficient post-discard coverage: $N8_REASON"
            ;;
          *)
            # Unrecognized INSUFFICIENT reason: do not silently classify an
            # unknown failure mode as anomalous-but-complete.
            add_reason "N8 per-interval gate could not evaluate (unrecognized INSUFFICIENT reason): $N8_REASON"
            ;;
        esac
        ;;
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

# ---- VALIDITY_CLASS: computed last, after every gate above has run --------
# See the header comment's "VALIDITY SEMANTICS CHANGE" section. `VALID`
# (hence the compatibility `valid` column) is "no" if and only if some
# independently-justified gate called add_reason -- that already includes
# N8's two genuine-failure INSUFFICIENT sub-cases, since those call
# add_reason themselves above. N8_ANOMALY_REASON is non-empty only for N8's
# two anomalous-but-complete outcomes, which never call add_reason.
if [ "$VALID" = "no" ]; then
  VALIDITY_CLASS="INVALID"
  ANOMALY_REASON=""
elif [ -n "$N8_ANOMALY_REASON" ]; then
  VALIDITY_CLASS="VALID_ANOMALOUS"
  ANOMALY_REASON="$N8_ANOMALY_REASON"
else
  VALIDITY_CLASS="VALID_NORMAL"
  ANOMALY_REASON=""
fi

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
    printf 'n8_verdict,n8_reason,'
    printf 'qdisc_packets,qdisc_dropped,qdisc_overlimits,qdisc_backlog,'
    printf 'runtime_or_socket_errors,valid,validity_class,invalid_reason,anomaly_reason,notes,instr_fields,'
    printf 'window_discard_s,window_duration_s,window_sample_count,'
    printf 'window_mech_app_limited,window_mech_unsent_pending,window_mech_ack_pending,'
    printf 'window_mech_app_limited_pct,window_mech_unsent_pending_pct,window_mech_ack_pending_pct\n'
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

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$RUN_ID" "$CELL_ID" "$SET" "$CONFIG" "$SND_BUF" "$QUEUELEN" "$SEG" "$TCP_WND" \
  "$RTT_TARGET" "$MEASURED_RTT" "$REP" \
  "$BYTES" "$DURATION" "$UBUNTU_MBPS" "$RTT_MBPS" \
  "${N8_VERDICT:-not_run}" "$(csvq "$N8_REASON")" \
  "$PACKETS" "$DROPPED" "$OVERLIMITS" "$BACKLOG" \
  "$ERRORS" "$VALID" "$VALIDITY_CLASS" "$(csvq "$REASON")" "$(csvq "$ANOMALY_REASON")" "$(csvq "$NOTES")" "$(csvq "$INSTR_BLOB")" \
  "$WINDOW_DISCARD_S" "$WINDOW_DURATION_S" "$WINDOW_SAMPLE_COUNT" \
  "$WINDOW_APP" "$WINDOW_UNSENT" "$WINDOW_ACK" \
  "$WINDOW_APP_PCT" "$WINDOW_UNSENT_PCT" "$WINDOW_ACK_PCT" >> "$RESULTS_CSV"

echo "== recorded $RUN_ID ($CELL_ID, $CONFIG, rep $REP, ${RTT_TARGET}ms) -> valid=$VALID validity_class=$VALIDITY_CLASS ${REASON:+($REASON)} ${ANOMALY_REASON:+[anomaly: $ANOMALY_REASON]} =="
echo "-- appended to $RESULTS_CSV"

# ---- COMPLETE marker: only after the row is written AND cited artifacts ---
# still exist on disk right now. Does not depend on VALID.
ARTIFACTS_OK="yes"
[ -n "$INSTR_JSON" ] && [ ! -f "$INSTR_JSON" ] && ARTIFACTS_OK="no"
[ -n "$HOST_CSV" ]   && [ ! -f "$HOST_CSV" ]   && ARTIFACTS_OK="no"
[ -n "$BOOT_BANNER" ] && [ ! -f "$BOOT_BANNER" ] && ARTIFACTS_OK="no"
[ -n "$TRACE" ]      && [ ! -f "$TRACE" ]      && ARTIFACTS_OK="no"

if [ "$ARTIFACTS_OK" = "yes" ]; then
  {
    echo "run_id=$RUN_ID"
    echo "recorded_utc=$(date -u +%Y%m%dT%H%M%SZ)"
    echo "valid=$VALID"
    echo "instr_json=${INSTR_JSON:-none}"
    echo "host_csv=${HOST_CSV:-none}"
    echo "trace=${TRACE:-none}"
  } > "$COMPLETE_MARKER"
  echo "-- marked COMPLETE: $COMPLETE_MARKER"
else
  echo "-- NOT marked COMPLETE: a cited artifact file is missing (row was still written above)"
fi
