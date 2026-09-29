# mx-rosetta-monitor

Continuous `check:data` runner for MultiversX Rosetta (`mx-chain-rosetta`) using `mesh-cli`, with reconciliation monitoring.

This repo does **not** reimplement validation. It wires together:

- `adapter` x4 (`proxyToObserverAdapter` from `mx-chain-rosetta/systemtests`) — translates gateway API (`https://gateway.multiversx.com`) into observer API for Rosetta, same as `check_with_mesh_cli.py:optionally_run_proxy_to_observer_adapter`
- `rosetta` x4 (shard 0, 1, 2, metachain) — one instance per shard (single-shard perspective, see `mx-chain-rosetta/README.md`), each pointed at its adapter
- `mesh-cli check:data` x4 — tip-follower, persistent `data-dir`, per-shard `:status_port`
- `monitor` — polls each `mesh-*/:9091/` (`CheckDataStatus{stats,progress}`), exposes Prometheus metrics, logs + Slack on reconciliation failure
- `prometheus` + `alertmanager` — scrape + alert on `failed_reconciliations > 0` / target down / tip lag

Upstream one-shot tooling (`mx-chain-rosetta/systemtests/check_with_mesh_cli.py`) deletes `data_dir` and exits on `reconciliation_coverage` — good for CI, wrong for 24/7. Here we keep state and run forever.

## Quickstart (mainnet)

1. No own observer needed by default: each `adapter-N` forwards to `PROXY_URL` (default `https://gateway.multiversx.com`). Gateway rate-limits apply — raise `ADAPTER_DELAY_MS` if you see 429s. For full-archive historical depth use your own observers via a compose override (see `.env.example` `DIRECT_OBSERVER_URL_*`).

2. Configure:

```bash
cp .env.example .env
# edit PROXY_URL, FIRST_HISTORICAL_EPOCH, NUM_HISTORICAL_EPOCHS, SLACK_WEBHOOK_URL
```

3. Run:

```bash
make up      # build + start everything
make status  # curl all mesh status endpoints
make logs    # follow mesh + monitor logs
```

Compose maps:

| shard | adapter (host) | rosetta | mesh status (host) |
|---|---|---|---|
| 0 | localhost:10001 | localhost:7091 | localhost:9091 |
| 1 | localhost:10002 | localhost:7092 | localhost:9092 |
| 2 | localhost:10003 | localhost:7093 | localhost:9093 |
| meta (4294967295) | localhost:10004 | localhost:7094 | localhost:9094 |

Monitor metrics: `localhost:8081/metrics` (`MONITOR_PORT`). Prometheus: `localhost:9090`. Grafana: `localhost:3000` (admin/admin) with pre-provisioned **MX Mesh CLI** dashboard. Alertmanager: `localhost:9095`.

## How reconciliation monitoring works

`mesh-cli` exposes `GET :<status_port>/` → `CheckDataStatus` (`pkg/results/data_results.go`):

```json
{"stats": {"blocks": 1, "failed_reconciliations": 2, "reconciliation_coverage": 0.99},
 "progress": {"blocks": 123, "tip": 125, "reconciler_queue_size": 5}}
```

`monitor/monitor.py` polls every `POLL_INTERVAL_SEC` (default 30):

- `mx_mesh_up{shard}` — 1 if status fetch ok, else 0
- `mx_mesh_failed_reconciliations{shard}` — alert if `> 0` or increasing
- `mx_mesh_skipped_reconciliations{shard}`, `mx_mesh_coverage{shard}`, `mx_mesh_tip_lag{shard}`
- logs `RECONCILIATION FAILURE shard=X failed=N` + POSTs to Slack if `SLACK_WEBHOOK_URL` set
- Prometheus rule `prometheus/rules.yml` fires `MeshReconciliationFailure`, `MeshDown`, `MeshTipLag`.

`check-data.json` sets `"ignore_reconciliation_error": false` so `mesh-cli` exits non-zero on failure — compose `restart: unless-stopped` brings it back, and the monitor + `results_output_file` (`/data/results.json`) preserve the error for triage. Never delete `/var/lib/mesh-cli/*` volumes in prod (the python systemtest does `shutil.rmtree` — don't copy that).

## Config

- `config/check-data.json` — shared base, based on `mx-chain-rosetta/systemtests/mesh_cli_config/check-data.json`, but with `"results_output_file": "/data/results.json"`, no terminating `end_conditions.index`, and `status_port` overridden per-service via `--status-port` flag.
- `config/mainnet-custom-currencies.json` — copied from systemtests.
- `.env` — observer URLs, epochs, ports, Slack webhook. Rosetta flags mirror `mx-chain-rosetta/cmd/rosetta/cli.go` (`--network-id=1 --network-name=mainnet --native-currency=EGLD --num-shards=3 --handle-contracts`).

## Useful commands

```bash
make config      # docker compose config (validate)
make up / make down
docker compose logs -f mesh-0 rosetta-0 monitor
curl -s localhost:9091/ | jq '{failed: .stats.failed_reconciliations, coverage: .stats.reconciliation_coverage, lag: (.progress.tip - .progress.blocks)}'
cat /var/lib/docker/volumes/mx-rosetta-monitor_mesh-data-0/_data/results.json  # or docker compose exec mesh-0 cat /data/results.json
```

## Notes / limits

- `mesh-cli` needs `ulimit -n 10000` (compose sets `ulimits.nofile`). See mesh-cli README troubleshooting.
- Historical lookup requires archived observer DB; without it set `historical_balance_disabled=true` (much less efficient reconciliation) — not recommended for mainnet watch.
- `Dockerfile.mesh-cli` builds `coinbase/mesh-cli v0.10.x` (`master`). Pin `MESH_CLI_REPO`/`MESH_CLI_REF` in `.env` to use your fork.
- `Dockerfile.rosetta` builds `multiversx/mx-chain-rosetta` at `ROSETTA_REF`. Override `ROSETTA_IMAGE` to use prebuilt.
