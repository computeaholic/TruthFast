#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

MODE="${1:---hash}"

snapshot_namespaced_kind() {
  local kind="$1"
  kubectl get "$kind" -A -o json 2>/dev/null || printf '{"apiVersion":"v1","items":[]}'
}

snapshot_cluster_kind() {
  local kind="$1"
  kubectl get "$kind" -o json 2>/dev/null || printf '{"apiVersion":"v1","items":[]}'
}

snapshot_payload() {
  {
    snapshot_namespaced_kind 'pod,endpoints,job,configmap,service,deployment,daemonset,statefulset,authorizationpolicy,peerauthentication,serviceentry,telemetry,gateway,httproute'
    snapshot_cluster_kind 'mutatingwebhookconfiguration,validatingwebhookconfiguration,clusterpolicy,clusterissuer,namespace'
  } \
  | jq -s 'map(.items // [])
  | add
  | map(
      del(
        .metadata.uid,
        .metadata.resourceVersion,
        .metadata.creationTimestamp,
        .metadata.generation,
        .metadata.managedFields,
        .metadata.selfLink,
        .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
        .metadata.annotations."deployment.kubernetes.io/revision",
        .metadata.annotations."kubectl.kubernetes.io/restartedAt",
        .metadata.annotations."control-plane.alpha.kubernetes.io/leader",
        .metadata.ownerReferences,
        .status
      )
    )
  | sort_by(.apiVersion, .kind, .metadata.namespace // "", .metadata.name // "")
  | {resources: .}'
}

case "$MODE" in
  --json)
    snapshot_payload
    ;;
  --hash)
    snapshot_payload | jq -S . | sha256sum | awk '{print $1}'
    ;;
  *)
    echo "[FAIL] unsupported snapshot mode: $MODE" >&2
    exit 2
    ;;
esac
