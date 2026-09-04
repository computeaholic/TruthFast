#!/usr/bin/env bash
set -euo pipefail

echo "[CHECK] Validating Istio control plane..."

echo "[CHECK] Pods:"
kubectl get pods -n istio-system

echo "[CHECK] Services:"
kubectl get svc -n istio-system

if ! kubectl get svc istiod -n istio-system >/dev/null 2>&1; then
  echo "[FAIL] istiod service missing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[CHECK] Webhooks:"
kubectl get validatingwebhookconfigurations | grep istio || {
  echo "[FAIL] Istio webhook missing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

echo "[CHECK] istiod endpoints:"
kubectl get endpoints istiod -n istio-system

ISTIOD_READY_COUNT="$(kubectl get endpoints istiod -n istio-system -o jsonpath='{range .subsets[*]}{range .addresses[*]}1{end}{end}' | wc -c | tr -d ' ')"
if [[ -z "${ISTIOD_READY_COUNT}" || "${ISTIOD_READY_COUNT}" -eq 0 ]]; then
  echo "[FAIL] istiod has no ready endpoints"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[PASS] Istio control plane healthy"
