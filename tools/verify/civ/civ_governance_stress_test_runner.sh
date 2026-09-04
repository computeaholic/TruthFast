#!/usr/bin/env bash
# requires_identity=true  # trust_tier=partial

if ! bash platform/runtime/operator/identity_enforcer.sh --require-partial >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires partial or full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

# tools/verify/civ/civ_governance_stress_test_runner.sh
# Runs CPU and Memory civ tests sequentially and consolidates artifacts into one governance-stress-test artifact set.

set -euo pipefail

TS=$(date -u +%Y%m%dT%H%M%SZ)
ART=artifacts/civ/governance-stress-test/${TS}
mkdir -p "${ART}"

# Temporary outputs
TMP_CPU=$(mktemp -t civ_cpu.XXXXXX)
TMP_MEM=$(mktemp -t civ_mem.XXXXXX)

EXIT=0
if tools/verify/civ/civ_cpu_governance_test.sh >"${TMP_CPU}" 2>&1; then
  echo "CPU test succeeded"
else
  echo "CPU test failed" >&2
  EXIT=1
fi

if tools/verify/civ/civ_memory_governance_test.sh >"${TMP_MEM}" 2>&1; then
  echo "Memory test succeeded"
else
  echo "Memory test failed" >&2
  EXIT=1
fi

# Build combined OUTPUT.txt
{
  echo "================================================================="
  echo " THREADFORGE :: CIV :: COMBINED GOVERNANCE STRESS TEST (read-only)"
  echo "================================================================="
  echo ""
  echo "--- CPU GOVERNANCE OUTPUT ---"
  sed -n '1,400p' "${TMP_CPU}"
  echo ""
  echo "--- MEMORY GOVERNANCE OUTPUT ---"
  sed -n '1,400p' "${TMP_MEM}"
  echo ""
  echo "--- UNCERTAINTY & COVERAGE REPORT ---"
  # Attribution counts
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "SELECT count() AS total_rows, countIf(coalesce(ol.identity_class, '') != '') AS attributed_rows, countIf(coalesce(ol.identity_class, '') = '') AS unattributed_rows FROM value_plane.memory_usage_snapshots AS m LEFT JOIN ( SELECT identity_class, JSONExtractString(payload, 'pod') AS pod, JSONExtractString(payload, 'namespace') AS namespace, max(created_at) AS latest_seen FROM value_plane.operator_ledger GROUP BY identity_class, pod, namespace ) ol ON m.pod = ol.pod AND m.namespace = ol.namespace" --format=Pretty
  echo ""
  echo "--- GOVERNANCE STATEMENT ---"
  echo "Combined CPU + Memory governance stress test executed; read-only and advisory in nature."
} > "${ART}/OUTPUT.txt"

# METADATA
GIT_SHA=$(git rev-parse --verify HEAD 2>/dev/null || echo "unknown")
cat > "${ART}/METADATA.yaml" <<EOF
timestamp: ${TS}
git_sha: ${GIT_SHA}
hostname: $(hostname)
user: $(whoami)
EOF

echo "${GIT_SHA}" > "${ART}/GIT_SHA"

cat > "${ART}/CLAIMS.md" <<'CLAIM'
This combined execution runs the CPU and Memory governance stress tests sequentially. It is read-only, uses live value-plane data, produces deterministic artifacts, and surfaces attribution and uncertainty gaps explicitly. No runtime mutations, cronjobs, enrichment pipelines, or enforcement actions were performed by this run.

CLAIM

# Copy raw independent artifacts into combined dir for traceability
mkdir -p "${ART}/raw"
if compgen -G "artifacts/civ/cpu-governance-test/*/OUTPUT.txt" >/dev/null; then
  cp -r artifacts/civ/cpu-governance-test/* "${ART}/raw/" 2>/dev/null || true
fi
if compgen -G "artifacts/civ/memory-governance-test/*/OUTPUT.txt" >/dev/null; then
  cp -r artifacts/civ/memory-governance-test/* "${ART}/raw/" 2>/dev/null || true
fi

# Cleanup
rm -f "${TMP_CPU}" "${TMP_MEM}"

if [ ${EXIT} -ne 0 ]; then
  echo "One or more tests failed. Artifacts: ${ART}" >&2
  exit ${EXIT}
else
  echo "Combined test completed successfully. Artifacts: ${ART}"
  exit 0
fi
