#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

# test_prompt_injection.sh — proof-path wrapper for prompt_injection.sh
#
# Verifies that research-agent is denied from restricted writer-agent endpoints,
# proving prompt manipulation cannot expand runtime identity privileges.
# Exits 10 (MISSING_PREREQ) if agents-lab namespace or deployments are absent.

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
NS="agents-lab"

if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  echo "[FAIL] agents-lab namespace not deployed — containment lab not active"
  exit 10
fi

if ! kubectl -n "${NS}" get deploy/research-agent >/dev/null 2>&1 || \
   ! kubectl -n "${NS}" get deploy/writer-agent   >/dev/null 2>&1; then
  echo "[FAIL] containment lab deployments not ready"
  exit 10
fi

bash "${REPO_ROOT}/platform/labs/agent-containment/scenarios/prompt_injection.sh"
