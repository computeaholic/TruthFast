#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

# test_agent_identities.sh — proof-path wrapper for identity_evidence.sh
#
# Verifies SPIFFE_ID env vars are present on core lab agent deployments.
# Exits 10 (MISSING_PREREQ) if the agents-lab namespace is not deployed.

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
NS="agents-lab"

if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  echo "[FAIL] agents-lab namespace not deployed — containment lab not active"
  exit 10
fi

bash "${REPO_ROOT}/platform/labs/agent-containment/scenarios/identity_evidence.sh"
