#!/bin/bash
# Build exactly one frozen TCP configuration from experiment/manifest.yaml.
# Usage: set_config.sh <BASE|B1|C1|C2|D1|D2>
#
# - Edits ONLY the three targeted macros in rtconfig.h/.config for the chosen
#   configuration; every other value is left untouched.
# - Rebuilds with scons -j2.
# - Verifies the EFFECTIVE compiled values via the compiler's own preprocessor
#   (arm-none-eabi-gcc -E -dM), not by trusting the source edit.
# - Verifies netutils iperf is linked exactly once.
# - Fails loudly (non-zero exit, clear message) on ANY mismatch. Never
#   silently proceeds with a wrong configuration.
set -euo pipefail

BSP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$BSP_DIR"

CFG="${1:?Usage: set_config.sh <BASE|B1|C1|C2|D1|D2>}"

case "$CFG" in
  BASE) SND_BUF=8196;  QUEUELEN=22; SEG=40 ;;
  B1)   SND_BUF=16384; QUEUELEN=22; SEG=40 ;;
  C1)   SND_BUF=8196;  QUEUELEN=30; SEG=40 ;;
  C2)   SND_BUF=8196;  QUEUELEN=40; SEG=40 ;;
  D1)   SND_BUF=8196;  QUEUELEN=22; SEG=60 ;;
  D2)   SND_BUF=8196;  QUEUELEN=22; SEG=80 ;;
  *) echo "FATAL: unknown config id '$CFG'. Must be one of: BASE B1 C1 C2 D1 D2" >&2; exit 1 ;;
esac

echo "== set_config: $CFG -> SND_BUF=$SND_BUF QUEUELEN=$QUEUELEN SEG=$SEG =="

sed -i -E "s/#define RT_LWIP_TCP_SND_BUF [0-9]+/#define RT_LWIP_TCP_SND_BUF $SND_BUF/" rtconfig.h
sed -i -E "s/#define RT_LWIP_TCP_SND_QUEUELEN [0-9]+/#define RT_LWIP_TCP_SND_QUEUELEN $QUEUELEN/" rtconfig.h
sed -i -E "s/#define RT_LWIP_TCP_SEG_NUM [0-9]+/#define RT_LWIP_TCP_SEG_NUM $SEG/" rtconfig.h
sed -i -E "s/CONFIG_RT_LWIP_TCP_SND_BUF=[0-9]+/CONFIG_RT_LWIP_TCP_SND_BUF=$SND_BUF/" .config
sed -i -E "s/CONFIG_RT_LWIP_TCP_SND_QUEUELEN=[0-9]+/CONFIG_RT_LWIP_TCP_SND_QUEUELEN=$QUEUELEN/" .config
sed -i -E "s/CONFIG_RT_LWIP_TCP_SEG_NUM=[0-9]+/CONFIG_RT_LWIP_TCP_SEG_NUM=$SEG/" .config

echo "-- rtconfig.h now reads:"
grep -n "RT_LWIP_TCP_SND_BUF\b\|RT_LWIP_TCP_SND_QUEUELEN\b\|RT_LWIP_TCP_SEG_NUM\b" rtconfig.h

echo "-- building (scons -j2)"
if ! scons -j2 2>&1 | tee /tmp/set_config_build.log | tail -15; then
  echo "FATAL: build failed for config $CFG. See /tmp/set_config_build.log" >&2
  exit 1
fi
if grep -qiE "error|warning" /tmp/set_config_build.log; then
  echo "FATAL: build produced warnings/errors for config $CFG:" >&2
  grep -iE "error|warning" /tmp/set_config_build.log >&2
  exit 1
fi

echo "-- verifying effective values via compiler preprocessor"
DUMP="$(mktemp)"
"$(dirname "${BASH_SOURCE[0]}")/dump_macros.sh" > "$DUMP" 2>&1

EFF_SNDBUF="$(grep -oP '^#define RT_LWIP_TCP_SND_BUF \K[0-9]+' "$DUMP" || true)"
EFF_QUEUELEN="$(grep -oP '^#define RT_LWIP_TCP_SND_QUEUELEN \K[0-9]+' "$DUMP" || true)"
EFF_SEG="$(grep -oP '^#define RT_LWIP_TCP_SEG_NUM \K[0-9]+' "$DUMP" || true)"

fail=0
[ "$EFF_SNDBUF" = "$SND_BUF" ]   || { echo "FATAL: effective TCP_SND_BUF=$EFF_SNDBUF, expected $SND_BUF" >&2; fail=1; }
[ "$EFF_QUEUELEN" = "$QUEUELEN" ] || { echo "FATAL: effective TCP_SND_QUEUELEN=$EFF_QUEUELEN, expected $QUEUELEN" >&2; fail=1; }
[ "$EFF_SEG" = "$SEG" ]           || { echo "FATAL: effective MEMP_NUM_TCP_SEG=$EFF_SEG, expected $SEG" >&2; fail=1; }
[ "$fail" -eq 0 ] || { rm -f "$DUMP"; exit 1; }

echo "-- verifying netutils iperf is linked exactly once"
IPERF_COUNT="$(arm-none-eabi-nm rtthread.elf | grep -c '^[0-9a-f]* T iperf$' || true)"
if [ "$IPERF_COUNT" != "1" ]; then
  echo "FATAL: expected exactly 1 linked 'iperf' symbol, found $IPERF_COUNT" >&2
  rm -f "$DUMP"
  exit 1
fi

rm -f "$DUMP"
echo "== OK: $CFG confirmed. TCP_SND_BUF=$EFF_SNDBUF TCP_SND_QUEUELEN=$EFF_QUEUELEN MEMP_NUM_TCP_SEG=$EFF_SEG, iperf linked. =="
arm-none-eabi-size rtthread.elf
