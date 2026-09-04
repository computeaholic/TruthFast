#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"

kubectl apply -f "$(dirname "$0")/../../platform/labs/agent-containment/k8s/namespace.yaml"

if [[ "$(kubectl get namespace "${NS}" -o jsonpath='{.metadata.labels.istio-injection}')" != "enabled" ]]; then
	echo "[FAIL] Namespace ${NS} is not labeled for sidecar injection"
	exit 2
fi

echo "[OK] Namespace prepared with sidecar injection"
