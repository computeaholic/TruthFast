#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="threadforge"
CONTEXT_NAME="kind-${CLUSTER_NAME}"
CONTROL_PLANE_NAME="kind-${CLUSTER_NAME}-control-plane"
ALT_CONTROL_PLANE_NAME="${CLUSTER_NAME}-control-plane"

# Check if kind cluster exists.
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "[cluster] kind cluster missing"
  exit 10
fi

# Check if control-plane container is running.
if ! docker ps --format '{{.Names}}' | grep -Eq "^(${CONTROL_PLANE_NAME}|${ALT_CONTROL_PLANE_NAME})$"; then
  echo "[cluster] control plane container not running"
  exit 10
fi

# Ensure kubectl uses the expected live context.
kubectl config use-context "${CONTEXT_NAME}" >/dev/null

# Check API server reachability.
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "[cluster] API server unreachable"
  exit 10
fi

echo "[cluster] healthy"
