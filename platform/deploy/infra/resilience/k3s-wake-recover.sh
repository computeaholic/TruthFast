#!/bin/sh
# Idempotent wake/recovery script for k3s hosts
# - Performs a quick DNS UDP probe to kube-dns ClusterIP
# - If UDP probe fails and cooldown elapsed, PATCHes kube-dns Service annotation to force kube-proxy re-sync
# - Safe, non-destructive action mirroring the diagnostic step used earlier

set -euo pipefail
NS=kube-system
SVC=kube-dns
KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
COOLDOWN_SECONDS=${COOLDOWN_SECONDS:-300}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found; please install kubectl or set KUBECONFIG to a machine with kubectl available" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

CLUSTER_IP=$(kubectl -n ${NS} get svc ${SVC} -o jsonpath='{.spec.clusterIP}')
if [ -z "${CLUSTER_IP}" ]; then
  echo "[WARN] could not determine ${SVC} ClusterIP" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Check last patch annotation, support epoch or ISO
ANN=$(kubectl -n ${NS} get svc ${SVC} -o jsonpath='{.metadata.annotations.threadforge/reconcile}' 2>/dev/null || true)
if [ -z "${ANN}" ]; then
  ANN=$(kubectl -n ${NS} get svc ${SVC} -o jsonpath='{.metadata.annotations.threadforge/wake-reconcile}' 2>/dev/null || true)
fi

NOW=$(date +%s)
LAST=0
if [ -n "${ANN}" ]; then
  if printf "%s" "${ANN}" | grep -qE '^[0-9]+$'; then
    LAST=${ANN}
  else
    LAST=$(date -d "${ANN}" +%s 2>/dev/null || 0)
  fi
fi

if [ "${LAST}" -gt 0 ] && [ $((NOW - LAST)) -lt ${COOLDOWN_SECONDS} ]; then
  echo "Cooldown active (last patch ${LAST}); skipping patch."
  exit 0
fi

# probe
if command -v dig >/dev/null 2>&1; then
  if ! dig @${CLUSTER_IP} +time=2 +tries=1 istiod.istio-system.svc >/dev/null 2>&1; then
    FAILED=1
  else
    FAILED=0
  fi
else
  if ! nslookup istiod.istio-system.svc ${CLUSTER_IP} >/dev/null 2>&1; then
    FAILED=1
  else
    FAILED=0
  fi
fi

if [ "${FAILED}" -eq 1 ]; then
  echo "DNS UDP probe failed, patching ${SVC} annotation to force kube-proxy resync"
  kubectl -n ${NS} patch svc ${SVC} -p '{"metadata":{"annotations":{"threadforge/reconcile":"'"$(date +%s)"'"}}}' --type=merge || true
else
  echo "DNS UDP probe OK"
fi

exit 0
