"""Poll mesh-cli check:data status endpoints, expose Prometheus metrics, alert on reconciliation issues.

Polls MESH_TARGETS="shard0=http://mesh-0:9091,shard1=http://mesh-1:9091,..."
Each target returns CheckDataStatus{stats,progress} (see mesh-cli pkg/results/data_results.go).

Metrics (port 8080):
  mx_mesh_up{shard}
  mx_mesh_failed_reconciliations{shard}
  mx_mesh_skipped_reconciliations{shard}
  mx_mesh_coverage{shard}
  mx_mesh_tip_lag{shard}
  mx_mesh_reconciler_queue{shard}
  mx_mesh_synced_block{shard}
  mx_mesh_tip_block{shard}
  mx_mesh_volume_bytes{shard}
"""
import json
import logging
import os
import subprocess
import time

import requests
from prometheus_client import Gauge, start_http_server

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mx-mesh-monitor")

TARGETS = {
    kv.split("=", 1)[0]: kv.split("=", 1)[1]
    for kv in os.environ.get(
        "MESH_TARGETS",
        "shard0=http://mesh-0:9091,shard1=http://mesh-1:9091,shard2=http://mesh-2:9091,meta=http://mesh-meta:9091",
    ).split(",")
    if "=" in kv
}
POLL = int(os.environ.get("POLL_INTERVAL_SEC", "30"))
SLACK = os.environ.get("SLACK_WEBHOOK_URL", "")
TIP_LAG_WARN = int(os.environ.get("TIP_LAG_WARN", "50"))
TIP_LAG_CRIT = int(os.environ.get("TIP_LAG_CRIT", "200"))

g_up = Gauge("mx_mesh_up", "1 if mesh-cli status fetch ok", ["shard"])
g_failed = Gauge("mx_mesh_failed_reconciliations", "failed reconciliations", ["shard"])
g_skipped = Gauge("mx_mesh_skipped_reconciliations", "skipped reconciliations", ["shard"])
g_coverage = Gauge("mx_mesh_coverage", "reconciliation coverage 0..1", ["shard"])
g_lag = Gauge("mx_mesh_tip_lag", "tip - synced blocks", ["shard"])
g_queue = Gauge("mx_mesh_reconciler_queue", "reconciler queue size", ["shard"])
g_synced = Gauge("mx_mesh_synced_block", "last synced block index", ["shard"])
g_tip = Gauge("mx_mesh_tip_block", "network tip block index", ["shard"])
g_vol = Gauge("mx_mesh_volume_bytes", "mesh data volume size in bytes (du)", ["shard"])

VOLUME_PATHS = {
    kv.split("=", 1)[0]: kv.split("=", 1)[1]
    for kv in os.environ.get("VOLUME_PATHS", "").split(",")
    if "=" in kv
}


def dir_size_bytes(path: str) -> int | None:
    try:
        out = subprocess.run(
            ["du", "-sb", path], capture_output=True, text=True, timeout=25
        )
        if out.returncode == 0:
            return int(out.stdout.split()[0])
    except Exception as e:  # noqa: BLE001
        log.error("du failed path=%s err=%s", path, e)
    return None

last_failed: dict[str, int] = {}
last_up: dict[str, bool] = {}


def results_error(shard: str, lines: int = 3, limit: int = 500) -> str | None:
    """First lines of mesh-cli /data/results.json error (volume is mounted ro)."""
    path = VOLUME_PATHS.get(shard, "")
    if not path:
        return None
    try:
        with open(f"{path}/results.json", encoding="utf-8", errors="replace") as f:
            err = (json.load(f).get("error") or "").strip().splitlines()
        return "\n".join(err[:lines])[:limit] or None
    except Exception:  # noqa: BLE001 - missing/corrupt file means no detail
        return None


STARTED = time.time()
GRACE = int(os.environ.get("STARTUP_GRACE_SEC", "60"))


def notify(text: str) -> None:
    log.warning(text)
    # ponytail: skip posts right after (re)start, state is empty and everything looks down; logs still show it
    if time.time() - STARTED < GRACE:
        return
    if not SLACK:
        return
    try:
        requests.post(SLACK, json={"text": text}, timeout=10)
    except Exception as e:  # noqa: BLE001 - alerting must not crash loop
        log.error("slack post failed: %s", e)


def check_once() -> None:
    for shard, base in TARGETS.items():
        url = base.rstrip("/") + "/"
        try:
            r = requests.get(url, timeout=15)
            r.raise_for_status()
            s = r.json()
            stats, prog = s.get("stats") or {}, s.get("progress") or {}
            failed = int(stats.get("failed_reconciliations", 0))
            skipped = int(stats.get("skipped_reconciliations", 0))
            coverage = float(stats.get("reconciliation_coverage", 0) or 0)
            tip = int(prog.get("tip") or 0)
            synced = int(prog.get("blocks") or 0)
            lag = tip - synced
            queue = int(prog.get("reconciler_queue_size", 0) or 0)

            g_up.labels(shard).set(1)
            if last_up.get(shard, True) is False:
                notify(f"MESH RECOVERED - shard: {shard}")
            last_up[shard] = True
            g_failed.labels(shard).set(failed)
            g_skipped.labels(shard).set(skipped)
            g_coverage.labels(shard).set(coverage)
            g_lag.labels(shard).set(lag)
            g_queue.labels(shard).set(queue)
            g_synced.labels(shard).set(synced)
            g_tip.labels(shard).set(tip)

            prev = last_failed.get(shard, 0)
            if failed > 0 and failed != prev:
                detail = results_error(shard)
                msg = (f"RECONCILIATION FAILURE - shard: {shard}\n"
                       f"failed: {failed}, skipped: {skipped}, coverage: {coverage:.4f}, lag: {lag}, queue: {queue}")
                notify(msg + (f"\nresults:\n{detail}" if detail else ""))
            last_failed[shard] = failed

            if lag >= TIP_LAG_CRIT:
                log.warning("TIP LAG CRIT shard=%s lag=%d tip=%s blocks=%s", shard, lag, prog.get("tip"), prog.get("blocks"))
            elif lag >= TIP_LAG_WARN:
                log.info("tip lag warn shard=%s lag=%d", shard, lag)
            else:
                log.info("ok shard=%s failed=%d coverage=%.4f lag=%d", shard, failed, coverage, lag)
        except Exception as e:
            g_up.labels(shard).set(0)
            if last_up.get(shard, True):
                detail = results_error(shard)
                msg = (f"MESH DOWN - shard: {shard}\n"
                       f"err: {e}")
                notify(msg + (f"\nresults:\n{detail}" if detail else ""))
            last_up[shard] = False
            log.error("fetch failed shard=%s url=%s err=%s", shard, url, e)

    for shard, path in VOLUME_PATHS.items():
        size = dir_size_bytes(path)
        if size is not None:
            g_vol.labels(shard).set(size)


def main() -> None:
    log.info("targets=%s poll=%ss", TARGETS, POLL)
    start_http_server(8080)
    while True:
        check_once()
        time.sleep(POLL)


if __name__ == "__main__":
    main()
