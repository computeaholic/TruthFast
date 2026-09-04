#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "[FAIL] CROSS_LAYER_INCONSISTENT: $1"
  exit 2
}

tempo_pod="tempo-0"
collector_pod="$(kubectl get pods -n observability -l app=threadforge-collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$collector_pod" ]] || fail "threadforge-collector pod not found"

tempo_certs="$TMP_DIR/tempo-certs.json"
collector_certs="$TMP_DIR/collector-certs.json"

kubectl exec -n observability "$tempo_pod" -c istio-proxy -- curl -sf http://127.0.0.1:15000/certs >"$tempo_certs" 2>/dev/null || \
  fail "unable to read Tempo Envoy certificates"
kubectl exec -n observability "$collector_pod" -c istio-proxy -- curl -sf http://127.0.0.1:15000/certs >"$collector_certs" 2>/dev/null || \
  fail "unable to read collector Envoy certificates"

grep -q 'spiffe://identity.threadforge.local/ns/observability/sa/tempo' "$tempo_certs" || \
  fail "Tempo Envoy certificate missing expected SPIFFE identity"
grep -q 'spiffe://identity.threadforge.local/ns/observability/sa/threadforge-collector' "$collector_certs" || \
  fail "collector Envoy certificate missing expected SPIFFE identity"

policy_count="$(kubectl get authorizationpolicy -n observability -o name 2>/dev/null | wc -l | tr -d ' ')"
[[ "$policy_count" -gt 0 ]] || fail "observability namespace has no AuthorizationPolicy resources"

kubectl exec -n observability statefulset/tempo -- wget -qO- http://localhost:3100/ready >/dev/null 2>&1 || \
  fail "Tempo readiness endpoint unavailable"

echo "[PASS] cross_layer_consistency=PASS"
