#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

# test_rogue_agent.sh — proof-path wrapper for rogue_agent.sh
#
# Verifies that the rogue-agent workload is denied from all protected services,
# proving unauthorized workload identities cannot traverse containment boundaries.
# Exits 10 (MISSING_PREREQ) if agents-lab namespace or rogue-agent is not deployed.

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
NS="agents-lab"

if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  echo "[FAIL] agents-lab namespace not deployed — containment lab not active"
  exit 10
fi

if ! kubectl -n "${NS}" get deploy/rogue-agent >/dev/null 2>&1; then
  echo "[FAIL] rogue-agent deployment not present — build and deploy before running"
  exit 10
fi

bash "${REPO_ROOT}/platform/labs/agent-containment/scenarios/rogue_agent.sh"
