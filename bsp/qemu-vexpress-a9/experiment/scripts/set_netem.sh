#!/bin/bash
# Apply and verify a constant, one-sided, jitter-free netem delay on tap0.
# Usage: set_netem.sh <delay_ms>
#
# Fails loudly if the resulting qdisc is not EXACTLY a single netem instance
# with the requested delay and nothing else (no jitter/loss/rate/dup/reorder/
# corrupt, no stacked fq_codel or other qdisc).
set -euo pipefail

DELAY_MS="${1:?Usage: set_netem.sh <delay_ms>}"

if ! [[ "$DELAY_MS" =~ ^[0-9]+$ ]]; then
  echo "FATAL: delay must be a positive integer (ms), got '$DELAY_MS'" >&2
  exit 1
fi

echo "== applying: tc qdisc replace dev tap0 root netem delay ${DELAY_MS}ms =="
sudo tc qdisc replace dev tap0 root netem delay "${DELAY_MS}ms"

LINE="$(tc qdisc show dev tap0)"
echo "-- tc qdisc show dev tap0:"
echo "$LINE"

if ! echo "$LINE" | grep -q "^qdisc netem"; then
  echo "FATAL: root qdisc on tap0 is not netem: $LINE" >&2
  exit 1
fi
if ! echo "$LINE" | grep -q "delay ${DELAY_MS}ms"; then
  echo "FATAL: configured delay is not exactly ${DELAY_MS}ms: $LINE" >&2
  exit 1
fi
for bad in jitter loss rate duplicate reorder corrupt; do
  if echo "$LINE" | grep -qi "$bad"; then
    echo "FATAL: unexpected '$bad' term present in netem config: $LINE" >&2
    exit 1
  fi
done

echo "-- tc -s qdisc show dev tap0:"
tc -s qdisc show dev tap0

echo "== OK: tap0 root is a clean netem, delay=${DELAY_MS}ms, no jitter/loss/rate/dup/reorder/corrupt =="
