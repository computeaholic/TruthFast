#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# CI wrapper boundary: adapt execution assumptions without changing
# canonical reset semantics.
export THREADFORGE_EXECUTION_PROFILE="ci"
export THREADFORGE_HOST_TRUST_MUTATION="denied"
export THREADFORGE_CI_HOST_TRUST_MODE="verify-only"
export CI_RUNNER_CERT_PHASE="cluster-reset"

bash "${REPO_ROOT}/scripts/ci/runner_pretrust_gate.sh" --phase "${CI_RUNNER_CERT_PHASE}"

bash "${REPO_ROOT}/scripts/ci/reset_ci_cluster.sh"
