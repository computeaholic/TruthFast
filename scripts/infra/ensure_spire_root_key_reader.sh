#!/usr/bin/env bash
set -euo pipefail

SPIRE_ROLLOUT_TIMEOUT="${SPIRE_ROLLOUT_TIMEOUT:-180}"
REGISTRY_HOSTPORT="${REGISTRY_HOSTPORT:-${THREADFORGE_REGISTRY:-registry.threadforge.local:30500}}"
POD_NAME="spire-root-key-reader"
BUSYBOX_IMAGE="${REGISTRY_HOSTPORT}/mirror/docker.io/library/busybox@sha256:bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469"

command -v jq >/dev/null 2>&1 || { echo "[FAIL] jq not found" >&2; exit 2; }

spire_server_pod="$(kubectl get pods -n spire-system -l app=spire-server -o json \
  | jq -r '
      .items[]
      | select(.status.phase == "Running")
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | .metadata.name
    ' | head -n1)"
[[ -n "$spire_server_pod" ]] || { echo "[FAIL] ready spire-server pod not found" >&2; exit 2; }

spire_server_json="$(kubectl get pod "$spire_server_pod" -n spire-system -o json)"
spire_server_node="$(jq -r '.spec.nodeName // empty' <<<"$spire_server_json")"
spire_server_data_volume="$(jq -c '.spec.volumes[] | select(.name == "server-data")' <<<"$spire_server_json")"
[[ -n "$spire_server_node" && -n "$spire_server_data_volume" && "$spire_server_data_volume" != "null" ]] || {
  echo "[FAIL] active spire-server data volume contract unavailable" >&2
  exit 2
}

if kubectl get pod "$POD_NAME" -n spire-system >/dev/null 2>&1; then
  if kubectl wait -n spire-system --for=condition=Ready "pod/${POD_NAME}" --timeout=5s >/dev/null 2>&1; then
    reader_json="$(kubectl get pod "$POD_NAME" -n spire-system -o json)"
    reader_node="$(jq -r '.spec.nodeName // empty' <<<"$reader_json")"
    reader_data_volume="$(jq -c '.spec.volumes[] | select(.name == "server-data")' <<<"$reader_json")"
    if [[ "$reader_node" == "$spire_server_node" && "$reader_data_volume" == "$spire_server_data_volume" ]]; then
      exit 0
    fi
  fi
  kubectl delete pod "$POD_NAME" -n spire-system --wait=true >/dev/null
fi

jq -n \
  --arg name "$POD_NAME" \
  --arg node "$spire_server_node" \
  --arg image "$BUSYBOX_IMAGE" \
  --argjson data_volume "$spire_server_data_volume" \
  '{
    apiVersion: "v1",
    kind: "Pod",
    metadata: {name: $name, namespace: "spire-system"},
    spec: {
      nodeName: $node,
      restartPolicy: "Never",
      imagePullSecrets: [{name: "registry-credentials"}],
      containers: [{
        name: "reader",
        image: $image,
        command: ["/bin/sh", "-ec", "sleep 2147483647"],
        volumeMounts: [{name: "server-data", mountPath: "/run/spire/data", readOnly: true}]
      }],
      volumes: [$data_volume]
    }
  }' | kubectl apply -f - >/dev/null

kubectl wait -n spire-system --for=condition=Ready "pod/${POD_NAME}" --timeout="${SPIRE_ROLLOUT_TIMEOUT}s" >/dev/null
