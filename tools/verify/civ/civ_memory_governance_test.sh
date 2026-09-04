#!/usr/bin/env bash
# requires_identity=true  # trust_tier=partial

if ! bash platform/runtime/operator/identity_enforcer.sh --require-partial >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires partial or full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

# tools/verify/civ/civ_memory_governance_test.sh
# Canonical Memory Governance Stress Test (read-only, identity-scoped, deterministic artifacts)

set -euo pipefail

# No args accepted
if [ "$#" -ne 0 ]; then
  echo "ERROR: This script accepts no arguments" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

echo ""
echo "================================================================="
echo " THREADFORGE :: CIV :: MEMORY GOVERNANCE STRESS TEST (read-only)"
echo "================================================================="

# Execution core (do NOT change SQL semantics below)
kubectl -n threadforge-system exec -i sts/clickhouse -- bash << 'EOF'
set -euo pipefail

echo ""
echo "=============================="
echo " THREADFORGE :: MEMORY DEMO"
echo "=============================="
echo ""

echo "▶ 1) BASELINE MEMORY STATE (REAL EXECUTION)"
clickhouse-client --format=Pretty << 'SQL'
SELECT
  recorded_at,
  namespace,
  pod,
  container,
  memory_bytes
FROM value_plane.memory_usage_snapshots
ORDER BY recorded_at DESC
LIMIT 20;
SQL

echo ""
echo "▶ 2) IDENTITY-LEVEL AGGREGATION"
clickhouse-client --format=Pretty << 'SQL'
SELECT
  recorded_at,
  identity_class,
  sum(memory_bytes) AS total_memory_bytes,
  count() AS sample_count
FROM value_plane.memory_usage_snapshots
GROUP BY recorded_at, identity_class
ORDER BY total_memory_bytes DESC
LIMIT 50;
SQL

echo ""
echo "▶ 3) BASELINE ENVELOPE (HISTORICAL CONTEXT)"
clickhouse-client --format=Pretty << 'SQL'
SELECT
  recorded_at,
  round(avg(memory_bytes),0) AS baseline_avg_24h,
  quantileExact(0.95)(memory_bytes) AS baseline_p95,
  count() AS sample_count_24h
FROM value_plane.memory_usage_snapshots
WHERE recorded_at >= now() - INTERVAL 24 HOUR
GROUP BY recorded_at
ORDER BY recorded_at DESC
LIMIT 50;
SQL

echo ""
echo "▶ 4) HEADROOM & EXHAUSTION (ADVISORY)"
clickhouse-client --format=Pretty << 'SQL'
SELECT
  identity_class,
  last_1h_total,
  baseline_avg_24h,
  round(last_1h_total / (baseline_avg_24h + 1e-9), 4) AS current_over_baseline,
  round(last_1h_total / (baseline_p95 + 1e-9), 4) AS advisory_exhaustion_ratio
FROM (
  SELECT
    coalesce(identity_class, '') AS identity_class,
    sumIf(memory_bytes, recorded_at >= now() - INTERVAL 1 HOUR) AS last_1h_total,
    avgIf(memory_bytes, recorded_at >= now() - INTERVAL 24 HOUR) AS baseline_avg_24h,
    quantileExact(0.95)(memory_bytes) AS baseline_p95
  FROM value_plane.memory_usage_snapshots
  GROUP BY identity_class
) ORDER BY current_over_baseline DESC
LIMIT 100;
SQL

echo ""
echo "▶ 5) POLICY COUNTERFACTUALS (WHAT IF MEMORY WAS SCALED?)"
clickhouse-client --format=Pretty << 'SQL'
SELECT
  scenario_name,
  identity_class,
  sum(memory_bytes * compute_multiplier) AS simulated_memory_bytes
FROM (
  SELECT * FROM value_plane.policy_scenarios
) s
JOIN (
  SELECT identity_class, sum(memory_bytes) AS memory_bytes FROM value_plane.memory_usage_snapshots GROUP BY identity_class
) m
  ON 1=1
GROUP BY scenario_name, identity_class
ORDER BY simulated_memory_bytes DESC
LIMIT 100;
SQL

echo ""
echo "▶ 5) GOVERNANCE STATEMENT"
echo "Memory snapshots are governance inputs only — read-only, observational, and explicitly marked as governance input."
echo ""
echo "▶ DEMO COMPLETE — NO EXECUTION MUTATED"
echo ""
EOF

# If we reach this point, the demo completed successfully
exit 0
