#!/usr/bin/env bash
# tools/verify/civ/civ_memory_governance_test_runner.sh
# Runner: executes the canonical civ_memory_governance_test.sh and produces artifacts.

set -euo pipefail

TS=$(date -u +%Y%m%dT%H%M%SZ)
ART=artifacts/civ/memory-governance-test/${TS}
mkdir -p "${ART}"

TMP_OUT=$(mktemp -t civ_memory_governance.XXXXXX)
EXIT=0
if tools/verify/civ/civ_memory_governance_test.sh >"${TMP_OUT}" 2>&1 ; then
  EXIT=0
else
  EXIT=$?
fi

cp "${TMP_OUT}" "${ART}/OUTPUT.txt" || true
rm -f "${TMP_OUT}"

GIT_SHA=$(git rev-parse --verify HEAD 2>/dev/null || echo "unknown")
cat > "${ART}/METADATA.yaml" <<EOF
timestamp: ${TS}
git_sha: ${GIT_SHA}
hostname: $(hostname)
user: $(whoami)
EOF

echo "${GIT_SHA}" > "${ART}/GIT_SHA"

cat > "${ART}/CLAIMS.md" <<'CLAIM'
This execution is a read-only governance stress test using real execution data from the Value Plane (ClickHouse).

- No execution was mutated by this test.
- All values are derived from real runtime data (ClickHouse tables) and represent governance counterfactuals, not predictions.
- Memory snapshots are marked as governance inputs and are treated as observational only.
- This test is deterministic in as much as it relies on deterministic SQL snapshotting at the time run.

CLAIM

if [ ${EXIT} -ne 0 ]; then
  echo "Test failed (exit ${EXIT}). Artifacts: ${ART}" >&2
  exit ${EXIT}
else
  echo "Test completed successfully. Artifacts: ${ART}"
  exit 0
fi
