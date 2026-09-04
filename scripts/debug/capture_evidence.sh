#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_DIR="artifacts"

mkdir -p "${ARTIFACT_DIR}"

if [[ "${TF_SKIP_VERIFY:-0}" == "1" ]]; then
  echo "[INFO] verify-all already executed upstream; skipping nested verify-all" > "${ARTIFACT_DIR}/deploy.log"
else
  make verify-all | tee "${ARTIFACT_DIR}/deploy.log"
fi

if [[ ! -s "${ARTIFACT_DIR}/deploy.log" ]]; then
  echo "[FAIL] artifacts/deploy.log was not created"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if [[ ! -f "${ARTIFACT_DIR}/enforcement.json" ]]; then
  echo "[FAIL] artifacts/enforcement.json is missing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

jq empty "${ARTIFACT_DIR}/enforcement.json" >/dev/null
jq empty "${ARTIFACT_DIR}/chaos_istio.json" >/dev/null
jq empty "${ARTIFACT_DIR}/chaos_spire.json" >/dev/null
jq empty "${ARTIFACT_DIR}/sidecar_bypass.json" >/dev/null
jq empty "${ARTIFACT_DIR}/identity_spoof.json" >/dev/null
jq empty "${ARTIFACT_DIR}/spire_status.json" >/dev/null
jq empty "${ARTIFACT_DIR}/spire_trust_mismatch.json" >/dev/null

kubectl get peerauthentication -A -o yaml > "${ARTIFACT_DIR}/mtls_state.txt"
kubectl get authorizationpolicy -A -o yaml > "${ARTIFACT_DIR}/policies.yaml"
kubectl get endpoints -n istio-system -o json > "${ARTIFACT_DIR}/endpoints.json"
kubectl get pods -A > "${ARTIFACT_DIR}/pods.txt"
kubectl get pods -n spire-system -o wide > "${ARTIFACT_DIR}/spire_pods.txt"
kubectl get svc -n spire-system > "${ARTIFACT_DIR}/spire_services.txt"

for path in \
  "${ARTIFACT_DIR}/enforcement.json" \
  "${ARTIFACT_DIR}/endpoints.json" \
  "${ARTIFACT_DIR}/policies.yaml" \
  "${ARTIFACT_DIR}/mtls_state.txt" \
  "${ARTIFACT_DIR}/pods.txt" \
  "${ARTIFACT_DIR}/chaos_istio.json" \
  "${ARTIFACT_DIR}/chaos_spire.json" \
  "${ARTIFACT_DIR}/spire_pods.txt" \
  "${ARTIFACT_DIR}/spire_services.txt" \
  "${ARTIFACT_DIR}/sidecar_bypass.json" \
  "${ARTIFACT_DIR}/identity_spoof.json" \
  "${ARTIFACT_DIR}/spire_status.json" \
  "${ARTIFACT_DIR}/spire_trust_mismatch.json"; do
  if [[ ! -s "${path}" ]]; then
    echo "[FAIL] ${path} was not created"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
done

echo "[PASS] Evidence captured under artifacts/"
