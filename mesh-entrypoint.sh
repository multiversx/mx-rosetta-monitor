#!/bin/sh
set -eu
# Usage: mesh-entrypoint.sh <rosetta-host:port> <adapter-host:port> <status-port>
ROSETTA="${1:-rosetta-0:8091}"
ADAPTER="${2:-adapter-0:10001}"
STATUS_PORT="${3:-9091}"

# Wait for adapter observer API (also proves gateway reachability).
for i in $(seq 1 60); do
  if curl -s -m 5 "http://${ADAPTER}/node/status" >/dev/null 2>&1; then
    break
  fi
  echo "waiting for adapter ${ADAPTER} ($i/60)..."
  sleep 5
done

# Wait for rosetta /network/list before starting check:data (avoids instant crash-loop).
for i in $(seq 1 60); do
  if curl -s -m 5 -X POST "http://${ROSETTA}/network/list" -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1; then
    break
  fi
  echo "waiting for rosetta ${ROSETTA} ($i/60)..."
  sleep 5
done

# Fresh boot starts at tip (like systemtests/start_mesh_cli.sh):
#   LATEST_BLOCK=$(curl -s $OBSERVER/node/status | jq -r .data.metrics.erd_nonce)
#   mesh-cli check:data --start-block $LATEST_BLOCK
# Restarts resume from the persistent /data volume (no --start-block),
# otherwise every restart would skip ahead and drop coverage.
START_BLOCK_ARGS=""
if [ -n "$(find /data -mindepth 1 -not -name results.json -print -quit 2>/dev/null)" ]; then
  echo "resuming from existing /data (no --start-block)"
else
  LATEST_BLOCK="$(curl -s -m 10 "http://${ADAPTER}/node/status" | jq -r .data.metrics.erd_nonce 2>/dev/null || true)"
  case "${LATEST_BLOCK}" in
    ''|*[!0-9]*)
      echo "warn: could not fetch latest nonce from ${ADAPTER}, starting without --start-block"
      ;;
    *)
      echo "fresh /data, starting at tip block ${LATEST_BLOCK}"
      START_BLOCK_ARGS="--start-block ${LATEST_BLOCK}"
      ;;
  esac
fi

# shellcheck disable=SC2086
exec /usr/local/bin/mesh-cli check:data \
  --configuration-file=/config/check-data.json \
  --online-url="http://${ROSETTA}" \
  --data-dir=/data \
  --status-port="${STATUS_PORT}" \
  ${START_BLOCK_ARGS}
