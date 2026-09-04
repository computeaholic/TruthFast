#!/usr/bin/env bash
set -euo pipefail

PURGE_CRDS="false"
if [[ "${1:-}" == "--purge-crds" ]]; then
  PURGE_CRDS="true"
elif [[ -n "${1:-}" ]]; then
  echo "[FAIL] Unknown argument: ${1}"
  echo "[USAGE] bash scripts/reset_istio.sh [--purge-crds]"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[FAIL] jq is required but not found"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[RESET] Checking istio-system namespace state..."

if ! kubectl get ns istio-system -o json >/tmp/istio-system-ns.json 2>/dev/null; then
  echo "[RESET] Namespace istio-system not found; nothing to reset"
else
  NS_PHASE="$(jq -r '.status.phase' /tmp/istio-system-ns.json)"
  if [[ "${NS_PHASE}" == "Terminating" ]]; then
    echo "[RESET] Namespace is Terminating; removing finalizers"
    kubectl get ns istio-system -o json \
      | jq '.spec.finalizers=[]' \
      | kubectl replace --raw "/api/v1/namespaces/istio-system/finalize" -f -

    echo "[RESET] Waiting for full namespace deletion"
    kubectl wait --for=delete ns/istio-system --timeout=120s
  else
    echo "[RESET] Namespace is not Terminating (phase=${NS_PHASE}); skipping finalize cleanup"
  fi
fi

echo "[RESET] Verifying clean namespace state"
if kubectl get ns istio-system >/dev/null 2>&1; then
  echo "[FAIL] istio-system namespace still exists"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[RESET] istio-system namespace is fully removed"

if [[ "${PURGE_CRDS}" == "true" ]]; then
  echo "[RESET] Purging Istio CRDs (--purge-crds enabled)"
  ISTIO_CRDS="$(kubectl get crds | grep istio | awk '{print $1}')"
  if [[ -n "${ISTIO_CRDS}" ]]; then
    while IFS= read -r crd; do
      [[ -z "${crd}" ]] && continue
      kubectl delete crd "${crd}"
    done <<< "${ISTIO_CRDS}"
  else
    echo "[RESET] No Istio CRDs found"
  fi
fi

echo "[RESET] Completed"
