#!/usr/bin/env bash
set -euo pipefail

# Verify that Prometheus can scrape kube-apiserver /metrics with TLS+auth and that Content-Type is valid
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE=observability
VALID_RE='(?i)(text/plain|openmetrics)'

# Resolve the Prometheus server pod by its canonical label — no fallback permitted.
pod=$(kubectl -n "$NAMESPACE" get pod -l app=kube-prometheus-stack-prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$pod" ]]; then
  echo "[FAIL] CONTRACT_VIOLATION: no Prometheus pod found via canonical label in $NAMESPACE"
  exit 2
fi

echo "Using Prometheus pod: $pod"

# Fetch headers from the apiserver /metrics endpoint using the Prometheus pod's service account files
hdrs=$(kubectl -n "$NAMESPACE" exec "$pod" -- sh -c 'curl -sS -I --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" https://kubernetes.default.svc:443/metrics -m 10')
if [[ -z "$hdrs" ]]; then
  echo "[FAIL] CONTRACT_VIOLATION: no headers returned from kube-apiserver /metrics via Prometheus pod"
  exit 2
fi

echo "Headers from kube-apiserver:\n$hdrs"

content_type=$(printf "%s" "$hdrs" | grep -i "Content-Type" | head -n1 | sed 's/Content-Type: //I' | tr -d '\r')
if [[ -z "$content_type" ]]; then
  echo "[FAIL] CONTRACT_VIOLATION: no Content-Type header in kube-apiserver /metrics response"
  exit 2
fi

echo "Content-Type: $content_type"

if printf "%s" "$content_type" | grep -Eq "$VALID_RE"; then
  echo "[PASS] kube-apiserver /metrics Content-Type valid: $content_type"
  exit 0
else
  echo "[FAIL] CONTRACT_VIOLATION: Content-Type does not match allowed formats (text/plain or openmetrics): $content_type"
  exit 2
fi
