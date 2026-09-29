#!/bin/bash
# Build exactly one frozen configuration from experiment/manifest.yaml.
# Usage: set_config.sh <L0|L1|L2|STOCK|PINNED>
#
# Design context (see docs/tfg_evidence/08_design_rationale.md):
#   TCP_SND_BUF is the ladder (L0/L1/L2). TCP_SND_QUEUELEN and
#   MEMP_NUM_TCP_SEG are PINNED at 44/44 across the whole ladder -- the
#   minimum required by L2 = 32768 -- so that TCP_SND_BUF is a genuine
#   single factor. STOCK is the unpinned shipped configuration, used only
#   by the pinning control; PINNED is an alias for L0.
#
# - Edits ONLY the four targeted macros, in BOTH rtconfig.h and .config, so
#   the two can never drift (a TCP_WND drift between them was a real bug:
#   .config said 8196 while rtconfig.h said 2048, and any menuconfig run
#   would have silently changed the receive window mid-sweep).
# - Rebuilds with scons -j2.
# - Verifies the EFFECTIVE compiled values via the compiler's own
#   preprocessor (arm-none-eabi-gcc -E -dM), not by trusting the source edit.
# - Verifies netutils iperf is linked exactly once.
# - Archives the build log and the full macro dump per configuration under
#   docs/tfg_evidence/raw_logs/, so build-validity is an artifact and not a
#   remembered observation.
# - Fails loudly (non-zero exit, clear message) on ANY mismatch. Never
#   silently proceeds with a wrong configuration.
set -euo pipefail

BSP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RTT_ROOT="$(cd "$BSP_DIR/../.." && pwd)"
LOG_DIR="$RTT_ROOT/docs/tfg_evidence/raw_logs"
cd "$BSP_DIR"

CFG="${1:?Usage: set_config.sh <L0|L1|L2|STOCK|PINNED>}"

# TCP_WND is NOT a factor in this experiment. It is pinned here so that the
# two configuration files can never disagree about it again.
WND=2048

case "$CFG" in
  L0)     SND_BUF=8196;  QUEUELEN=44; SEG=44 ;;
  L1)     SND_BUF=16384; QUEUELEN=44; SEG=44 ;;
  L2)     SND_BUF=32768; QUEUELEN=44; SEG=44 ;;
  PINNED) SND_BUF=8196;  QUEUELEN=44; SEG=44 ;;   # alias of L0, pinning control
  STOCK)  SND_BUF=8196;  QUEUELEN=22; SEG=40 ;;   # shipped config, pinning control
  *) echo "FATAL: unknown config id '$CFG'. Must be one of: L0 L1 L2 STOCK PINNED" >&2; exit 1 ;;
esac

echo "== set_config: $CFG -> SND_BUF=$SND_BUF QUEUELEN=$QUEUELEN SEG=$SEG WND=$WND =="

mkdir -p "$LOG_DIR"

sed -i -E "s/#define RT_LWIP_TCP_SND_BUF [0-9]+/#define RT_LWIP_TCP_SND_BUF $SND_BUF/" rtconfig.h
sed -i -E "s/#define RT_LWIP_TCP_SND_QUEUELEN [0-9]+/#define RT_LWIP_TCP_SND_QUEUELEN $QUEUELEN/" rtconfig.h
sed -i -E "s/#define RT_LWIP_TCP_SEG_NUM [0-9]+/#define RT_LWIP_TCP_SEG_NUM $SEG/" rtconfig.h
sed -i -E "s/#define RT_LWIP_TCP_WND [0-9]+/#define RT_LWIP_TCP_WND $WND/" rtconfig.h
sed -i -E "s/CONFIG_RT_LWIP_TCP_SND_BUF=[0-9]+/CONFIG_RT_LWIP_TCP_SND_BUF=$SND_BUF/" .config
sed -i -E "s/CONFIG_RT_LWIP_TCP_SND_QUEUELEN=[0-9]+/CONFIG_RT_LWIP_TCP_SND_QUEUELEN=$QUEUELEN/" .config
sed -i -E "s/CONFIG_RT_LWIP_TCP_SEG_NUM=[0-9]+/CONFIG_RT_LWIP_TCP_SEG_NUM=$SEG/" .config
sed -i -E "s/CONFIG_RT_LWIP_TCP_WND=[0-9]+/CONFIG_RT_LWIP_TCP_WND=$WND/" .config

echo "-- rtconfig.h now reads:"
grep -n "RT_LWIP_TCP_SND_BUF\b\|RT_LWIP_TCP_SND_QUEUELEN\b\|RT_LWIP_TCP_SEG_NUM\b\|RT_LWIP_TCP_WND\b" rtconfig.h

echo "-- cross-checking rtconfig.h against .config (no drift permitted)"
drift=0
for pair in "RT_LWIP_TCP_SND_BUF:$SND_BUF" "RT_LWIP_TCP_SND_QUEUELEN:$QUEUELEN" \
            "RT_LWIP_TCP_SEG_NUM:$SEG" "RT_LWIP_TCP_WND:$WND"; do
  macro="${pair%%:*}"; want="${pair##*:}"
  h="$(grep -oP "^#define $macro \K[0-9]+" rtconfig.h || true)"
  c="$(grep -oP "^CONFIG_$macro=\K[0-9]+" .config || true)"
  if [ "$h" != "$want" ] || [ "$c" != "$want" ]; then
    echo "FATAL: $macro drift -- rtconfig.h='$h' .config='$c' expected='$want'" >&2
    drift=1
  fi
done
[ "$drift" -eq 0 ] || exit 1

BUILD_LOG="$LOG_DIR/build_${CFG}.log"
echo "-- building (scons -j2), log -> $BUILD_LOG"
if ! scons -j2 2>&1 | tee "$BUILD_LOG" | tail -15; then
  echo "FATAL: build failed for config $CFG. See $BUILD_LOG" >&2
  exit 1
fi
if grep -qiE "error|warning" "$BUILD_LOG"; then
  echo "FATAL: build produced warnings/errors for config $CFG:" >&2
  grep -iE "error|warning" "$BUILD_LOG" >&2
  exit 1
fi

echo "-- verifying effective values via compiler preprocessor"
DUMP="$LOG_DIR/macro_dump_${CFG}.txt"
"$(dirname "${BASH_SOURCE[0]}")/dump_macros.sh" > "$DUMP" 2>&1

EFF_SNDBUF="$(grep -oP '^#define RT_LWIP_TCP_SND_BUF \K[0-9]+' "$DUMP" || true)"
EFF_QUEUELEN="$(grep -oP '^#define RT_LWIP_TCP_SND_QUEUELEN \K[0-9]+' "$DUMP" || true)"
EFF_SEG="$(grep -oP '^#define RT_LWIP_TCP_SEG_NUM \K[0-9]+' "$DUMP" || true)"
EFF_WND="$(grep -oP '^#define RT_LWIP_TCP_WND \K[0-9]+' "$DUMP" || true)"

fail=0
[ "$EFF_SNDBUF" = "$SND_BUF" ]    || { echo "FATAL: effective TCP_SND_BUF=$EFF_SNDBUF, expected $SND_BUF" >&2; fail=1; }
[ "$EFF_QUEUELEN" = "$QUEUELEN" ] || { echo "FATAL: effective TCP_SND_QUEUELEN=$EFF_QUEUELEN, expected $QUEUELEN" >&2; fail=1; }
[ "$EFF_SEG" = "$SEG" ]           || { echo "FATAL: effective MEMP_NUM_TCP_SEG=$EFF_SEG, expected $SEG" >&2; fail=1; }
[ "$EFF_WND" = "$WND" ]           || { echo "FATAL: effective TCP_WND=$EFF_WND, expected $WND" >&2; fail=1; }
[ "$fail" -eq 0 ] || exit 1

echo "-- verifying netutils iperf is linked exactly once"
IPERF_COUNT="$(arm-none-eabi-nm rtthread.elf | grep -c '^[0-9a-f]* T iperf$' || true)"
if [ "$IPERF_COUNT" != "1" ]; then
  echo "FATAL: expected exactly 1 linked 'iperf' symbol, found $IPERF_COUNT" >&2
  exit 1
fi

echo "== OK: $CFG confirmed. TCP_SND_BUF=$EFF_SNDBUF TCP_SND_QUEUELEN=$EFF_QUEUELEN MEMP_NUM_TCP_SEG=$EFF_SEG TCP_WND=$EFF_WND, iperf linked. =="
arm-none-eabi-size rtthread.elf | tee -a "$BUILD_LOG"
echo "-- archived: $BUILD_LOG"
echo "-- archived: $DUMP"
