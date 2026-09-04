#!/usr/bin/env bash
set -euo pipefail

for namespace_name in agents-lab istio-system spire-system; do
  kubectl delete namespace "${namespace_name}" --ignore-not-found --wait=false
done

echo "[PASS] Environment reset requested for agents-lab, istio-system, spire-system"
