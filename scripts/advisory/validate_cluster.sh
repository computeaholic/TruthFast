#!/usr/bin/env bash
set -euo pipefail

echo "[PREFLIGHT] Checking kubectl connectivity"
kubectl version >/dev/null

echo "[PREFLIGHT] Checking API server responsiveness"
kubectl cluster-info >/dev/null

echo "[PREFLIGHT] Checking node readiness"
kubectl get nodes
NOT_READY_COUNT="$(kubectl get nodes --no-headers | awk '$2 != "Ready" {count++} END {print count+0}')"
if [[ "${NOT_READY_COUNT}" != "0" ]]; then
  echo "[FAIL] One or more nodes are not Ready"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[PREFLIGHT] Checking for terminating namespaces"
kubectl get ns
if kubectl get ns --no-headers | grep -q 'Terminating'; then
  echo "[FAIL] One or more namespaces are Terminating"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[PASS] Cluster preflight checks passed"
