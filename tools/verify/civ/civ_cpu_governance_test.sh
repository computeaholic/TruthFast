#!/usr/bin/env bash
# requires_identity=true  # trust_tier=partial

if ! bash platform/runtime/operator/identity_enforcer.sh --require-partial >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires partial or full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

# tools/verify/civ/civ_cpu_governance_test.sh
# Canonical CPU Governance Stress Test (read-only, identity-scoped, deterministic artifacts)

set -euo pipefail

# Short, self-contained script. Exits non-zero on failure. No args accepted.
if [ "$#" -ne 0 ]; then
  echo "ERROR: This script accepts no arguments" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

echo ""
echo "================================================================="
echo " THREADFORGE :: CIV :: CPU GOVERNANCE STRESS TEST (read-only)"
echo "================================================================="

# Execution core (do NOT change SQL semantics below)
kubectl -n threadforge-system exec -i sts/clickhouse -- bash << 'EOF'
set -euo pipefail

echo ""
echo "=============================="
echo " THREADFORGE :: IRONMAN DEMO"
echo "=============================="
echo ""

echo "▶ 1) BASELINE ECONOMIC TRUTH (REAL EXECUTION)"
clickhouse-client --format=Pretty << 'SQL'
SELECT
  identity_class,
  sum(total_cost_units) AS total_cost,
  sumIf(total_cost_units, source_ledger='value') AS execution_cost,
  sum(denial_units) AS denial_pressure
FROM value_plane.cost_model c
LEFT JOIN value_plane.denial_cost d
  ON c.event_id = d.event_id
GROUP BY identity_class;
SQL

echo ""
echo "▶ 2) CURRENT IDENTITY BUDGET STATE"
clickhouse-client --format=Pretty << 'SQL'
SELECT
    b.identity_class,
    b.budget_units,
    sum(c.total_cost_units) AS spent_units,
    round(sum(c.total_cost_units) / b.budget_units, 4) AS utilization
FROM value_plane.identity_budgets b
LEFT JOIN value_plane.cost_model c
  ON b.identity_class = c.identity_class
GROUP BY b.identity_class, b.budget_units;
SQL

echo ""
echo "▶ 3) BASELINE ENVELOPE (HISTORICAL CONTEXT)"
clickhouse-client --format=Pretty << 'SQL'
SELECT
  identity_class,
  round(avg(total_cost_units),2) AS baseline_avg_per_event,
  quantileExact(0.95)(total_cost_units) AS baseline_p95_per_event,
  count() AS sample_count_24h
FROM value_plane.cost_model
WHERE created_at >= now() - INTERVAL 24 HOUR
GROUP BY identity_class
ORDER BY baseline_avg_per_event DESC;
SQL

echo ""
echo "▶ 4) HEADROOM & EXHAUSTION (ADVISORY)"
clickhouse-client --format=Pretty << 'SQL'
SELECT
  identity_class,
  last_1h_total,
  baseline_avg_24h,
  round(last_1h_total / (baseline_avg_24h + 1e-9), 4) AS current_over_baseline
FROM (
  SELECT
    identity_class,
    sumIf(total_cost_units, created_at >= now() - INTERVAL 1 HOUR) AS last_1h_total,
    avgIf(total_cost_units, created_at >= now() - INTERVAL 24 HOUR) AS baseline_avg_24h
  FROM value_plane.cost_model
  GROUP BY identity_class
) ORDER BY current_over_baseline DESC;
SQL

echo ""
echo "▶ 5) POLICY COUNTERFACTUALS (WHAT IF WE CHANGED THE RULES?)"
clickhouse-client --format=Pretty << 'SQL'
SELECT
    s.scenario_name,
    c.identity_class,
    round(sum(c.total_cost_units * s.compute_multiplier), 2) AS simulated_compute_cost,
    round(sum(d.denial_units * s.denial_multiplier), 2) AS simulated_denial_cost,
    round(
        sum(c.total_cost_units * s.compute_multiplier)
      + sum(d.denial_units * s.denial_multiplier), 2
    ) AS simulated_total_cost
FROM value_plane.policy_scenarios s
CROSS JOIN value_plane.cost_model c
LEFT JOIN value_plane.denial_cost d
  ON c.event_id = d.event_id
GROUP BY s.scenario_name, c.identity_class
ORDER BY simulated_total_cost DESC;
SQL

echo ""
echo "▶ 4) BUDGET STRESS TEST (WOULD THIS BREAK US?)"
clickhouse-client --format=Pretty << 'SQL'
SELECT
    s.scenario_name,
    b.identity_class,
    b.budget_units,
    round(sum(c.total_cost_units * s.compute_multiplier), 2) AS projected_cost,
    round(sum(c.total_cost_units * s.compute_multiplier) / b.budget_units, 4) AS utilization,
    (sum(c.total_cost_units * s.compute_multiplier) / b.budget_units) >= 1 AS budget_breached
FROM value_plane.policy_scenarios s
CROSS JOIN value_plane.cost_model c
JOIN value_plane.identity_budgets b
  ON b.identity_class = c.identity_class
GROUP BY s.scenario_name, b.identity_class, b.budget_units
ORDER BY utilization DESC;
SQL

echo ""
echo "▶ 5) GOVERNANCE STATEMENT"
echo "ThreadForge treats vector databases as ephemeral semantic lenses,"
echo "not memory, not truth, and not authority."
echo ""

echo "▶ DEMO COMPLETE — NO EXECUTION MUTATED"
echo ""
EOF

# If we reach this point, the demo completed successfully
exit 0
