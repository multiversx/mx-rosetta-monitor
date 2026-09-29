#!/bin/sh
set -eu
# Usage: rosetta-entrypoint.sh <shard>  (0,1,2,4294967295)
SHARD="${1:-0}"
: "${OBSERVER_URL:?OBSERVER_URL env is required (http://adapter-N:1000X in compose)}"
: "${NETWORK_ID:?}"; : "${NETWORK_NAME:?}"
: "${FIRST_HISTORICAL_EPOCH:?}"; : "${NUM_HISTORICAL_EPOCHS:?}"

exec /usr/local/bin/rosetta \
  --port=8091 \
  --observer-http-url="${OBSERVER_URL}" \
  --observer-actual-shard="${SHARD}" \
  --network-id="${NETWORK_ID}" \
  --network-name="${NETWORK_NAME}" \
  --native-currency="${NATIVE_CURRENCY:-EGLD}" \
  --num-shards="${NUM_SHARDS:-3}" \
  --genesis-block="${GENESIS_BLOCK:-cd229e4ad2753708e4bab01d7f249affe29441829524c9529e84d51b6d12f2a7}" \
  --config-custom-currencies=/config/custom-currencies.json \
  --first-historical-epoch="${FIRST_HISTORICAL_EPOCH}" \
  --num-historical-epochs="${NUM_HISTORICAL_EPOCHS}" \
  --handle-contracts \
  --log-level='*:INFO' \
  --pprof
