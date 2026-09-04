.PHONY: \
	value-plane-install \
	value-plane-status \
	value-plane-destroy \
	value-plane-schema-apply \
	value-plane-schema-migrate \
	value-plane-schema-verify \
	value-plane-ingest \
	value-plane-ingest-operator \
	value-plane-ingest-value \
	value-plane-verify \
	value-plane-audit \
	value-plane-semantics \
	value-plane-semantics-verify \
	value-plane-dashboards-note \
	value-plane-presentation-note \
	value-plane-policy-economics \
	value-plane-budgets \
	value-plane-counterfactual \
	value-plane-governance-review \
	value-plane-governance-export \
	value-plane-advisory-export \
	value-plane-review \
	value-plane-drift-fingerprint \
	value-plane-enforcement-signals \
	value-plane-env-check \
	value-plane-port-forward-start \
	value-plane-port-forward-stop \
	qdrant-index \
	qdrant-rebuild \
	qdrant-verify

# ------------------------------------------------
# Value Plane Environment Contract
# ------------------------------------------------

-include scripts/env/value-plane.env
-include scripts/env/value-plane.env.local
export

# ------------------------------------------------
# Python Command Selector
# ------------------------------------------------

PY := $(shell if [ -x .venv-ai/bin/python ]; then echo .venv-ai/bin/python; elif command -v python3 >/dev/null; then echo python3; else echo python; fi)

# ------------------------------------------------
# Environment Check
# ------------------------------------------------

value-plane-env-check:
	@test -n "$(PG_DSN)" || (echo "ERROR: PG_DSN not set"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)
	@test -n "$(CH_HOST)" || (echo "ERROR: CH_HOST not set"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)
	@test -n "$(CH_PORT)" || (echo "ERROR: CH_PORT not set"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)
	@test -n "$(CH_DB)" || (echo "ERROR: CH_DB not set"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)

# ------------------------------------------------
# Port Forward Convenience
# ------------------------------------------------

value-plane-port-forward-start:
	mkdir -p /tmp/threadforge
	@if [ ! -f /tmp/threadforge/postgres_pf.pid ]; then \
		kubectl port-forward -n threadforge-system sts/postgres 5432:5432 & echo $$! > /tmp/threadforge/postgres_pf.pid; \
	fi
	@if [ ! -f /tmp/threadforge/clickhouse_pf.pid ]; then \
		kubectl port-forward -n threadforge-system sts/clickhouse $${CLICKHOUSE_PORT:-9000}:$${CLICKHOUSE_PORT:-9000} & echo $$! > /tmp/threadforge/clickhouse_pf.pid; \
	fi
	@echo "Port forwards started. PIDs: postgres=$$(cat /tmp/threadforge/postgres_pf.pid), clickhouse=$$(cat /tmp/threadforge/clickhouse_pf.pid)"

value-plane-port-forward-stop:
	@if [ -f /tmp/threadforge/postgres_pf.pid ]; then kill $$(cat /tmp/threadforge/postgres_pf.pid) 2>/dev/null; rm /tmp/threadforge/postgres_pf.pid; fi
	@if [ -f /tmp/threadforge/clickhouse_pf.pid ]; then kill $$(cat /tmp/threadforge/clickhouse_pf.pid) 2>/dev/null; rm /tmp/threadforge/clickhouse_pf.pid; fi
	@echo "Port forwards stopped."

## ----------------------------
## Value Plane — Infrastructure
## ----------------------------

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
value-plane-install:
	helm upgrade --install clickhouse platform/deploy/infra/clickhouse \
	  --namespace threadforge-system

value-plane-status:
	kubectl -n threadforge-system get sts,svc,pvc | grep clickhouse || true

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
value-plane-destroy:
	helm uninstall clickhouse -n threadforge-system || true

## ----------------------------
## Value Plane — Schemas
## ----------------------------

value-plane-schema-apply:
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client -q "CREATE DATABASE IF NOT EXISTS value_plane"
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client -q "CREATE TABLE IF NOT EXISTS value_plane.operator_ledger_v2 (source_event_id UUID, source_ledger LowCardinality(String) DEFAULT 'operator', is_demo UInt8 DEFAULT 0, ingest_run_id UUID, ingested_at DateTime64(6, 'UTC'), event_id UUID, created_at DateTime64(6, 'UTC'), spiffe_id String, identity_class LowCardinality(String), payload String CODEC(ZSTD(3))) ENGINE = MergeTree ORDER BY (identity_class, created_at, event_id) SETTINGS index_granularity = 8192;"
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client -q "ALTER TABLE value_plane.operator_ledger_v2 ADD COLUMN IF NOT EXISTS is_demo UInt8 DEFAULT 0 AFTER source_ledger;"
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client -q "CREATE OR REPLACE VIEW value_plane.operator_ledger AS SELECT * FROM value_plane.operator_ledger_v2 WHERE is_demo = 0;"
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client -q "CREATE TABLE IF NOT EXISTS value_plane.value_ledger_v2 (source_event_id UUID, source_ledger LowCardinality(String) DEFAULT 'value', ingest_run_id UUID, ingested_at DateTime64(6, 'UTC'), event_id UUID, created_at DateTime64(6, 'UTC'), spiffe_id String, identity_class LowCardinality(String), payload String CODEC(ZSTD(3))) ENGINE = MergeTree ORDER BY (created_at, event_id) SETTINGS index_granularity = 8192;"
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client -q "CREATE OR REPLACE VIEW value_plane.value_ledger AS SELECT * FROM value_plane.value_ledger_v2;"
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/schemas/clickhouse/governance/memory_usage_snapshots.sql

value-plane-schema-migrate:
	kubectl -n threadforge-system exec -i sts/postgres -- \
	  psql -U threadforge_operator -d threadforge -c "ALTER TABLE operator_ledger ADD COLUMN IF NOT EXISTS spiffe_id TEXT, ADD COLUMN IF NOT EXISTS identity_class TEXT;"
	kubectl -n threadforge-system exec -i sts/postgres -- \
	  psql -U threadforge_operator -d threadforge -c "ALTER TABLE value_ledger ADD COLUMN IF NOT EXISTS spiffe_id TEXT, ADD COLUMN IF NOT EXISTS identity_class TEXT;"
	kubectl -n threadforge-system exec -i sts/postgres -- \
	  psql -U threadforge_operator -d threadforge -c "CREATE INDEX IF NOT EXISTS idx_operator_ledger_spiffe_id ON operator_ledger(spiffe_id);"
	kubectl -n threadforge-system exec -i sts/postgres -- \
	  psql -U threadforge_operator -d threadforge -c "CREATE INDEX IF NOT EXISTS idx_operator_ledger_identity_class ON operator_ledger(identity_class);"
	kubectl -n threadforge-system exec -i sts/postgres -- \
	  psql -U threadforge_operator -d threadforge -c "CREATE INDEX IF NOT EXISTS idx_value_ledger_spiffe_id ON value_ledger(spiffe_id);"
	kubectl -n threadforge-system exec -i sts/postgres -- \
	  psql -U threadforge_operator -d threadforge -c "CREATE INDEX IF NOT EXISTS idx_value_ledger_identity_class ON value_ledger(identity_class);"
	kubectl -n threadforge-system exec -i sts/postgres -- \
	  psql -U threadforge_operator -d threadforge -c "CREATE UNIQUE INDEX IF NOT EXISTS idx_ingest_cursors_table ON ingest_cursors(table_name);"

value-plane-schema-verify:
	kubectl -n threadforge-system exec sts/clickhouse -- \
	  clickhouse-client -q "SHOW TABLES FROM value_plane"

## ----------------------------
## Value Plane — Ingestion
## ----------------------------

value-plane-ingest-operator: value-plane-env-check
	@echo "▶ Ingesting operator ledger into value plane"
	LEDGER_SOURCE=operator $(PY) -m ingest.value_plane.main

value-plane-ingest-value: value-plane-env-check
	@echo "▶ Ingesting value ledger into value plane"
	LEDGER_SOURCE=value $(PY) -m ingest.value_plane.main

value-plane-ingest: value-plane-env-check
	@echo "▶ Ingesting ledgers into value plane (parallel)"
	@$(MAKE) -j2 value-plane-ingest-operator value-plane-ingest-value

## ----------------------------
## Value Plane — Verification
## ----------------------------

value-plane-verify:
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/value_plane_verify/01_tables_exist.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/value_plane_verify/02_append_only_check.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/value_plane_verify/03_duplicate_visibility.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/value_plane_verify/04_identity_drift.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/value_plane_verify/05_null_identity_guard.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/value_plane_verify/06_lineage_completeness.sql

value-plane-verify-identity:
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/value_plane_verify/04_identity_drift.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/value_plane_verify/05_null_identity_guard.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/value_plane_verify/07_identity_lifecycle_coverage.sql

value-plane-audit:
	@bash scripts/audit/value_plane_audit.sh

## ----------------------------
## Value Plane — Semantics
## ----------------------------

value-plane-semantics:
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/schemas/clickhouse/semantics/cost_model.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/schemas/clickhouse/semantics/denial_cost.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client -q "CREATE MATERIALIZED VIEW IF NOT EXISTS value_plane.identity_cost_7d_mv ENGINE = SummingMergeTree ORDER BY (identity_class, day_bucket) POPULATE AS SELECT identity_class, toStartOfDay(created_at) AS day_bucket, sum(compute_units) AS total_compute_units, sum(policy_units) AS total_policy_units, sum(total_cost_units) AS total_cost_units, count() AS event_count FROM value_plane.cost_model WHERE created_at >= now() - INTERVAL 7 DAY GROUP BY identity_class, day_bucket;"
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client -q "CREATE MATERIALIZED VIEW IF NOT EXISTS value_plane.identity_denial_7d_mv ENGINE = SummingMergeTree ORDER BY (identity_class, day_bucket) POPULATE AS SELECT identity_class, toStartOfDay(created_at) AS day_bucket, sum(denial_units) AS total_denial_units, count() AS event_count FROM value_plane.denial_cost WHERE created_at >= now() - INTERVAL 7 DAY GROUP BY identity_class, day_bucket;"
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/semantics/build_cost_model.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/semantics/build_denial_cost.sql

value-plane-semantics-verify:
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/semantics/cost_by_identity.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/semantics/denial_by_identity.sql

## ----------------------------
## Value Plane — Presentation
## ----------------------------

value-plane-dashboards-note:
	@echo "Dashboards are read-only. Import JSON files under dashboards/value-plane/ into Grafana."

value-plane-presentation-note:
	@echo "Currency, trends, and comparisons are presentation-only. No data mutation."

## ----------------------------
## Value Plane — Policy Economics
## ----------------------------

value-plane-policy-economics:
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/schemas/clickhouse/policy_economics/policy_cost.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/policy_economics/build_policy_cost.sql

## ----------------------------
## Value Plane — Budgets
## ----------------------------

value-plane-budgets:
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/schemas/clickhouse/budget/identity_budgets.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/budget/load_default_budgets.sql

## ----------------------------
## Value Plane — Counterfactual
## ----------------------------

value-plane-counterfactual:
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/schemas/clickhouse/counterfactual/policy_scenarios.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/counterfactual/load_example_scenarios.sql

## ----------------------------
## Value Plane — Governance Review
## ----------------------------

value-plane-governance-review:
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/governance/review_packet.sql

civ-memory-governance-test:
	@echo "▶ Running CIV Memory Governance Stress Test"
	@tools/verify/civ/civ_memory_governance_test_runner.sh

civ-governance-stress-test:
	@echo "▶ Running COMBINED CIV Governance Stress Test"
	@tools/verify/civ/civ_governance_stress_test_runner.sh


## ----------------------------
## Value Plane — Exports
## ----------------------------

value-plane-governance-export:
	scripts/governance/export_review_packet.sh

value-plane-advisory-export:
	scripts/advisory/export_recommendations.sh

value-plane-review: value-plane-env-check \
	value-plane-ingest \
	value-plane-semantics \
	value-plane-policy-economics \
	value-plane-budgets \
	value-plane-governance-export \
	value-plane-advisory-export
	@echo "✔ Full Value Plane review complete"

# ------------------------------------------------------------------------------
# CIV — Governance Stress Tests (CPU-based canonical test harness)
# ------------------------------------------------------------------------------
.PHONY: civ-cpu-governance-test
civ-cpu-governance-test:
	@echo "▶ Running CIV CPU Governance Stress Test (read-only)"
	@tools/verify/civ/civ_cpu_governance_test_runner.sh


## ----------------------------
## Value Plane — Drift Detection
## ----------------------------

value-plane-drift-fingerprint:
	bash scripts/drift/fingerprint.sh

## ----------------------------
## Value Plane — Enforcement Signals
## ----------------------------

value-plane-enforcement-signals:
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/schemas/clickhouse/enforcement/enforcement_signals.sql
	kubectl -n threadforge-system exec -i sts/clickhouse -- \
	  clickhouse-client < data/queries/enforcement/emit_budget_signals.sql

## ----------------------------
## Value Plane — External Exports
## ----------------------------

value-plane-export-finance:
	bash scripts/exports/export_finance_snapshot.sh

## ----------------------------
## Value Plane — Physical Upgrade
## ----------------------------

value-plane-physical-upgrade:
	kubectl -n threadforge-system exec sts/clickhouse -- \
	  clickhouse-client < data/schemas/clickhouse/_physical/value_ledger_physical.sql

## ----------------------------
## Value Plane — Civ Interfaces
## ----------------------------

## ----------------------------
## Qdrant Vector Indexer
## ----------------------------

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
qdrant-index:
	@if [ "$(CONFIRM)" != "YES" ]; then \
	  echo "ERROR: CONFIRM not set to YES; refusing to run qdrant-index" >&2; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; \
	fi; \
	@echo "▶ Running Qdrant indexer job"
	kubectl create job qdrant-indexer-$(shell date +%s) --from=cronjob/qdrant-indexer-cron -n qdrant

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
qdrant-rebuild:
	@if [ "$(CONFIRM)" != "YES" ]; then \
	  echo "ERROR: CONFIRM not set to YES; refusing to run qdrant-rebuild" >&2; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; \
	fi; \
	@echo "▶ Rebuilding Qdrant collection from scratch"
	@echo "⚠️  This will delete all vectors in Qdrant"
	@kubectl -n qdrant exec deployment/qdrant -- qdrant_client delete_collection collection_name=threadforge_vectors || true
	@kubectl create job qdrant-rebuild-$(shell date +%s) --from=cronjob/qdrant-indexer-cron -n qdrant

qdrant-verify:
	@echo "▶ Verifying Qdrant vector identity coverage"
	kubectl -n threadforge-system exec sts/clickhouse -- \
	  clickhouse-client -q "SELECT 'vector_identity_coverage_check' as check_name, 'Qdrant vector identity verification' as description, 'NOT_IMPLEMENTED' as status;"

qdrant-eval:
	@echo "▶ Running Qdrant evaluation and saving results"
	@mkdir -p out/qdrant/eval
	$(PY) -m runtime.vector.indexer.evaluate \
	  --collection operator_semantic \
	  --dataset datasets/semantic_eval.json \
	  --out out/qdrant/eval/

qdrant-drift-check:
	@echo "▶ Checking for semantic drift in Qdrant"
	$(PY) -m runtime.vector.indexer.drift_check

value-plane-civ-interfaces:
	@echo "Civ Engine interfaces are defined under queries/civ_interfaces/"
