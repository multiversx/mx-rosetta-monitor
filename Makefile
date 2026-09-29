.PHONY: up down config logs status restart clean clean-compose-volumes

up:
	docker-compose up -d --build
	@echo "rosetta: 7091-7094, mesh status: 9091-9094, monitor: $${MONITOR_PORT:-8081}, prometheus: 9090"

down:
	docker-compose down

config:
	docker-compose config

logs:
	docker-compose logs -f mesh-0 mesh-1 mesh-2 mesh-meta monitor

status:
	@for p in 9091 9092 9093 9094; do echo "== :$$p =="; curl -s localhost:$$p/ | jq '{failed: .stats.failed_reconciliations, skipped: .stats.skipped_reconciliations, coverage: .stats.reconciliation_coverage, lag: (.progress.tip - .progress.blocks)}' || echo FAIL; done
	@echo "== monitor =="; curl -s localhost:$${MONITOR_PORT:-8081}/metrics | grep ^mx_mesh || echo "monitor down"

restart-mesh:
	docker-compose restart mesh-0 mesh-1 mesh-2 mesh-meta

# DANGER: wipes mesh-cli BadgerDB state. Only for fresh resync.
clean:
	docker compose down -v

# Wipes only the mesh-cli data volumes (fresh resync from tip on next up).
# Keeps prometheus-data.
clean-compose-volumes:
	docker volume rm mx-rosetta-monitor_mesh-data-0 mx-rosetta-monitor_mesh-data-1 mx-rosetta-monitor_mesh-data-2 mx-rosetta-monitor_mesh-data-meta
