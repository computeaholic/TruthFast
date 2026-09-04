#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts}"
mkdir -p "${ARTIFACT_DIR}"

log() {
  printf '[chaos] %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[FAIL] required command not found: $1"
    exit 2
  }
}

require_cluster() {
  kubectl cluster-info >/dev/null 2>&1 || {
    echo "[FAIL] cluster unreachable"
    exit 2
  }
}

find_workload_kind() {
  local ns="$1"
  local name="$2"

  if kubectl -n "$ns" get statefulset "$name" >/dev/null 2>&1; then
    echo "statefulset"
    return 0
  fi
  if kubectl -n "$ns" get deployment "$name" >/dev/null 2>&1; then
    echo "deployment"
    return 0
  fi

  return 1
}

get_replicas() {
  local ns="$1"
  local kind="$2"
  local name="$3"
  kubectl -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.replicas}'
}

scale_workload() {
  local ns="$1"
  local kind="$2"
  local name="$3"
  local replicas="$4"
  kubectl -n "$ns" scale "$kind" "$name" --replicas="$replicas" >/dev/null
}

rollout_wait() {
  local ns="$1"
  local kind="$2"
  local name="$3"
  local timeout="${4:-240s}"
  kubectl -n "$ns" rollout status "$kind/$name" --timeout="$timeout" >/dev/null
}

write_json() {
  local file="$1"
  local payload="$2"
  printf '%s\n' "$payload" > "$file"
  jq empty "$file" >/dev/null
}
