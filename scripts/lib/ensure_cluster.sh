#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLUSTER_NAME="threadforge"
CONTEXT_NAME="kind-${CLUSTER_NAME}"
CONTROL_PLANE_NAME="kind-${CLUSTER_NAME}-control-plane"
ALT_CONTROL_PLANE_NAME="${CLUSTER_NAME}-control-plane"
CANONICAL_KUBECONFIG_PATH="${HOME}/.kube/config"
DEFAULT_KIND_CONFIG_PATH="platform/build/kind/kind-config.yaml"
LEGACY_KIND_CONFIG_PATH="deploy/kind-config.yaml"

sync_kind_kubeconfig() {
  mkdir -p "$(dirname "${CANONICAL_KUBECONFIG_PATH}")"
  kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${CANONICAL_KUBECONFIG_PATH}" >/dev/null
  export KUBECONFIG="${CANONICAL_KUBECONFIG_PATH}"
}

resolve_kind_config_path() {
  if [[ -n "${KIND_CONFIG_PATH:-}" ]]; then
    echo "${KIND_CONFIG_PATH}"
    return 0
  fi
  if [[ -f "${DEFAULT_KIND_CONFIG_PATH}" ]]; then
    echo "${DEFAULT_KIND_CONFIG_PATH}"
    return 0
  fi
  if [[ -f "${LEGACY_KIND_CONFIG_PATH}" ]]; then
    echo "${LEGACY_KIND_CONFIG_PATH}"
    return 0
  fi
  return 1
}

ensure_kind_image_available() {
  local desired_image=""
  local node_image="registry.threadforge.local:30500/kindest-node@sha256:48321fb2717f92527d9aba9a9b32055dff622f9c356ea3de2f1ffb75344f87bf"

  desired_image="$(configured_kind_image 2>/dev/null || true)"
  if [[ -z "${desired_image}" ]]; then
    return 0
  fi

  if [[ ! "${desired_image}" =~ ^registry\.threadforge\.local:30500/.+@sha256:[0-9a-f]{64}$ ]]; then
    echo "[cluster] configured kind node image must be an internal digest-pinned reference: ${desired_image}" >&2
    return 1
  fi

  if [[ "${desired_image}" != "${node_image}" ]]; then
    echo "[cluster] configured kind node image mismatch: ${desired_image} != ${node_image}" >&2
    return 1
  fi

  echo "[cluster] verifying node image exists in registry"
  docker pull "${node_image}" >/dev/null 2>&1 || {
    echo "[FAIL] required node image missing from registry: ${node_image}"
    exit 2
  }
}

create_cluster() {
  local kind_config_path=""
  ensure_kind_image_available
  if kind_config_path="$(resolve_kind_config_path)"; then
    kind create cluster --name "${CLUSTER_NAME}" --config "${kind_config_path}"
  else
    kind create cluster --name "${CLUSTER_NAME}"
  fi
  sync_kind_kubeconfig
  kubectl config use-context "${CONTEXT_NAME}" >/dev/null
}

configured_kind_image() {
  local kind_config_path=""
  kind_config_path="$(resolve_kind_config_path)" || return 1
  awk '/^[[:space:]]*image:[[:space:]]*/ {print $2; exit}' "${kind_config_path}"
}

running_kind_image() {
  local container_name=""
  if docker ps --format '{{.Names}}' | grep -q "^${CONTROL_PLANE_NAME}$"; then
    container_name="${CONTROL_PLANE_NAME}"
  elif docker ps --format '{{.Names}}' | grep -q "^${ALT_CONTROL_PLANE_NAME}$"; then
    container_name="${ALT_CONTROL_PLANE_NAME}"
  else
    return 1
  fi
  docker inspect -f '{{.Config.Image}}' "${container_name}"
}

if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "[cluster] creating cluster"
  create_cluster
  exit 0
fi

if ! docker ps --format '{{.Names}}' | grep -Eq "^(${CONTROL_PLANE_NAME}|${ALT_CONTROL_PLANE_NAME})$"; then
  echo "[cluster] cluster exists but container is dead -- recreating"
  kind delete cluster --name "${CLUSTER_NAME}" || true
  create_cluster
  exit 0
fi

sync_kind_kubeconfig
kubectl config use-context "${CONTEXT_NAME}" >/dev/null

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "[cluster] kubeconfig stale -- recreating cluster"
  kind delete cluster --name "${CLUSTER_NAME}" || true
  create_cluster
  exit 0
fi

desired_image="$(configured_kind_image 2>/dev/null || true)"
current_image="$(running_kind_image 2>/dev/null || true)"
if [[ -n "${desired_image}" && -n "${current_image}" && "${desired_image}" != "${current_image}" ]]; then
  echo "[cluster] control-plane image mismatch (${current_image} != ${desired_image}) -- recreating cluster"
  kind delete cluster --name "${CLUSTER_NAME}" || true
  create_cluster
  exit 0
fi

echo "[cluster] already healthy"
