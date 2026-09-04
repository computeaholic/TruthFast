#!/usr/bin/env bash
# verify_bootstrap_converged.sh
# Validates that bootstrap has converged and all required components are ready
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "[bootstrap-converged] checking required namespaces exist"
for ns in cert-manager spire-system istio-system kyverno observability threadforge-test threadforge-system; do
  kubectl get namespace "$ns" >/dev/null 2>&1 || {
    echo "[FAIL] MISSING_NAMESPACE: $ns"
    exit 2
  }
done

echo "[bootstrap-converged] checking cert-manager readiness"
kubectl wait --for=condition=Available deployment -n cert-manager --all --timeout=180s >/dev/null || {
  echo "[FAIL] ROLLOUT_TIMEOUT: cert-manager deployments not ready"
  exit 2
}

echo "[bootstrap-converged] checking SPIRE server readiness"
kubectl rollout status statefulset/spire-server -n spire-system --timeout=180s >/dev/null || {
  echo "[FAIL] ROLLOUT_TIMEOUT: spire-server not ready"
  exit 2
}

echo "[bootstrap-converged] checking SPIRE agent readiness"
kubectl rollout status daemonset/spire-agent -n spire-system --timeout=180s >/dev/null || {
  echo "[FAIL] ROLLOUT_TIMEOUT: spire-agent not ready"
  exit 2
}

echo "[bootstrap-converged] checking Istio control plane readiness"
kubectl rollout status deployment/istiod -n istio-system --timeout=180s >/dev/null || {
  echo "[FAIL] ROLLOUT_TIMEOUT: istiod not ready"
  exit 2
}

echo "[bootstrap-converged] checking Kyverno readiness"
for deployment in kyverno-admission-controller kyverno-background-controller kyverno-cleanup-controller kyverno-reports-controller; do
  kubectl rollout status deployment/"$deployment" -n kyverno --timeout=180s >/dev/null || {
    echo "[FAIL] ROLLOUT_TIMEOUT: kyverno/$deployment not ready"
    exit 2
  }
done

echo "[bootstrap-converged] checking observability stack readiness"
kubectl rollout status statefulset/loki -n observability --timeout=180s >/dev/null || {
  echo "[FAIL] ROLLOUT_TIMEOUT: loki not ready"
  exit 2
}
kubectl rollout status statefulset/tempo -n observability --timeout=180s >/dev/null || {
  echo "[FAIL] ROLLOUT_TIMEOUT: tempo not ready"
  exit 2
}
kubectl rollout status deployment/grafana -n observability --timeout=180s >/dev/null || {
  echo "[FAIL] ROLLOUT_TIMEOUT: grafana not ready"
  exit 2
}

echo "[bootstrap-converged] checking test workloads readiness"
kubectl rollout status deployment/echo -n threadforge-test --timeout=180s >/dev/null || {
  echo "[FAIL] ROLLOUT_TIMEOUT: echo workload not ready"
  exit 2
}
kubectl rollout status deployment/test-client -n threadforge-test --timeout=180s >/dev/null || {
  echo "[FAIL] ROLLOUT_TIMEOUT: test-client workload not ready"
  exit 2
}

echo "[bootstrap-converged] checking sidecar injection"
injected_pods="$(kubectl get pods -n threadforge-test -o json | jq '[.items[] | select(any(.spec.containers[]?; .name == "istio-proxy"))] | length')"
if [[ "$injected_pods" -lt 1 ]]; then
  echo "[FAIL] SIDECAR_INJECTION: no injected pods in threadforge-test"
  exit 2
fi

echo "[bootstrap-converged] checking registry reachability"
status="$(docker exec threadforge-control-plane sh -c "curl -sS -k -o /dev/null -w '%{http_code}' https://registry.threadforge.local:30500/v2/" 2>/dev/null || true)"
if [[ "$status" != "200" && "$status" != "401" && "$status" != "403" ]]; then
  echo "[FAIL] REGISTRY_UNREACHABLE: registry returned HTTP $status"
  exit 2
fi

echo "[PASS] Bootstrap has converged - all required components are ready"
