#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

bash "$REPO_ROOT/scripts/verify/verify_control_plane_ready.sh"
bash "$REPO_ROOT/scripts/verify/verify_registry_completeness.sh"
bash "$REPO_ROOT/scripts/verify/verify_registry_tls_trust.sh" >/dev/null
bash "$REPO_ROOT/scripts/verify/ensure_test_workload.sh"

kubectl rollout status statefulset/loki -n observability --timeout=180s >/dev/null
kubectl rollout status statefulset/tempo -n observability --timeout=180s >/dev/null
kubectl rollout status deployment/grafana -n observability --timeout=180s >/dev/null

echo "[PASS] system integrity verified"
