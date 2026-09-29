.PHONY: up down config logs status restart-mesh clean clean-compose-volumes

COMPOSE_PROJECT_NAME ?= mx-rosetta-monitor
export COMPOSE_PROJECT_NAME

up:
	docker-compose up -d --build
	@mapped_monitor_port=$$(docker-compose port monitor 8080 2>/dev/null | sed 's/.*://'); \
		echo "rosetta: 7091-7094, mesh status: 9091-9094, monitor: $${mapped_monitor_port:-unknown}, prometheus: 9090"

down:
	docker-compose down

config:
	docker-compose config

logs:
	docker-compose logs --tail=100 -f mesh-0 mesh-1 mesh-2 mesh-meta monitor

status:
	@for service_name in mesh-0 mesh-1 mesh-2 mesh-meta; do \
		mapped_host_port=$$(docker-compose port "$$service_name" 9091 2>/dev/null | sed 's/.*://'); \
		echo "== $$service_name :$${mapped_host_port:-not-running} =="; \
		if [ -n "$$mapped_host_port" ]; then curl -fsS "localhost:$$mapped_host_port/" | jq '{failed: .stats.failed_reconciliations, skipped: .stats.skipped_reconciliations, coverage: .stats.reconciliation_coverage, lag: (.progress.tip - .progress.blocks)}' || echo FAIL; else echo FAIL; fi; \
	done
	@mapped_host_port=$$(docker-compose port monitor 8080 2>/dev/null | sed 's/.*://'); \
	echo "== monitor :$${mapped_host_port:-not-running} =="; \
	if [ -n "$$mapped_host_port" ]; then curl -fsS "localhost:$$mapped_host_port/metrics" | grep '^mx_mesh' || echo "monitor down"; else echo "monitor down"; fi

restart-mesh:
	docker-compose restart mesh-0 mesh-1 mesh-2 mesh-meta

# DANGER: wipes mesh-cli BadgerDB state. Only for fresh resync.
clean:
	docker compose down -v

# Wipes only the mesh-cli data volumes (fresh resync from tip on next up).
# Keeps prometheus-data.
clean-compose-volumes:
	docker volume rm $(COMPOSE_PROJECT_NAME)_mesh-data-0 $(COMPOSE_PROJECT_NAME)_mesh-data-1 $(COMPOSE_PROJECT_NAME)_mesh-data-2 $(COMPOSE_PROJECT_NAME)_mesh-data-meta
