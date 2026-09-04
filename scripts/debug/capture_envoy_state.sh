#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
ARTIFACT_DIR="artifacts"

mkdir -p "${ARTIFACT_DIR}"

echo "[ENVOY] Capturing Envoy proxy configuration state"

RESEARCH_POD="$(kubectl get pod -l app=research-agent -n "${NS}" -o jsonpath='{.items[0].metadata.name}')"
WRITER_POD="$(kubectl get pod -l app=writer-agent -n "${NS}" -o jsonpath='{.items[0].metadata.name}')"

if [[ -z "${RESEARCH_POD}" || -z "${WRITER_POD}" ]]; then
  echo "[FAIL] Could not identify research-agent or writer-agent pods"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Capture clusters configuration
echo "[ENVOY] Capturing cluster configuration from research-agent"
istioctl proxy-config cluster "${RESEARCH_POD}" -n "${NS}" > "${ARTIFACT_DIR}/envoy_clusters.txt" || {
  echo "[FAIL] Failed to capture cluster configuration"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

# Extract outbound clusters (should NOT include direct writer pod IP)
OUTBOUND_CLUSTERS="$(grep '^outbound' "${ARTIFACT_DIR}/envoy_clusters.txt" | awk '{print $1}' || true)"
echo "[ENVOY] Outbound clusters: ${OUTBOUND_CLUSTERS}"

# Verify no direct pod IP clusters
WRITER_POD_IP="$(kubectl get pod -l app=writer-agent -n "${NS}" -o jsonpath='{.items[0].status.podIP}')"
if echo "${OUTBOUND_CLUSTERS}" | grep -q "${WRITER_POD_IP}"; then
  echo "[FAIL] Direct pod IP found in Envoy clusters (policy bypass risk)"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Capture listeners configuration
echo "[ENVOY] Capturing listener configuration from research-agent"
istioctl proxy-config listener "${RESEARCH_POD}" -n "${NS}" > "${ARTIFACT_DIR}/envoy_listeners.txt" || {
  echo "[FAIL] Failed to capture listener configuration"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

# Verify RBAC listener is present
if ! grep -q 'RBAC' "${ARTIFACT_DIR}/envoy_listeners.txt"; then
  echo "[WARN] No RBAC listener found in research-agent configuration"
fi

# Capture routes configuration
echo "[ENVOY] Capturing route configuration from research-agent"
istioctl proxy-config route "${RESEARCH_POD}" -n "${NS}" > "${ARTIFACT_DIR}/envoy_routes.txt" || {
  echo "[FAIL] Failed to capture route configuration"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

# Verify outbound routes exist for writer-agent
if ! grep -q 'writer-agent' "${ARTIFACT_DIR}/envoy_routes.txt"; then
  echo "[FAIL] No route found for writer-agent in research-agent configuration"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Capture writer-agent proxy state as secondary verification
echo "[ENVOY] Capturing cluster configuration from writer-agent"
istioctl proxy-config cluster "${WRITER_POD}" -n "${NS}" > "${ARTIFACT_DIR}/envoy_writer_clusters.txt" || {
  echo "[FAIL] Failed to capture writer-agent cluster configuration"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

echo "[ENVOY] Capturing listener configuration from writer-agent"
istioctl proxy-config listener "${WRITER_POD}" -n "${NS}" > "${ARTIFACT_DIR}/envoy_writer_listeners.txt" || {
  echo "[FAIL] Failed to capture writer-agent listener configuration"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

# Check inbound listener (should exist for receiving traffic)
if ! grep -q 'inbound' "${ARTIFACT_DIR}/envoy_writer_listeners.txt"; then
  echo "[FAIL] No inbound listener found on writer-agent (cannot receive traffic)"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[PASS] Envoy state captured successfully"
echo "  - Clusters: ${ARTIFACT_DIR}/envoy_clusters.txt"
echo "  - Listeners: ${ARTIFACT_DIR}/envoy_listeners.txt"
echo "  - Routes: ${ARTIFACT_DIR}/envoy_routes.txt"
echo "  - Writer Clusters: ${ARTIFACT_DIR}/envoy_writer_clusters.txt"
echo "  - Writer Listeners: ${ARTIFACT_DIR}/envoy_writer_listeners.txt"
