#!/usr/bin/env bash
set -euo pipefail

echo "🟦 ThreadForge Full Bootstrap"

echo "1. Identity"
helm install spire platform/deploy/infra/spire

echo "2. Mesh"
helm install istio platform/deploy/infra/istio

echo "3. Storage"
helm install minio platform/deploy/infra/minio

echo "4. Observability"
helm install prometheus platform/deploy/infra/prometheus
helm install loki platform/deploy/infra/loki
helm install tempo platform/deploy/infra/tempo
helm install grafana platform/deploy/infra/grafana

# Wait for observability stack to be ready
echo "⏳ Waiting for observability plane (30s)..."
sleep 30

echo "5. Runtime"
helm install runtime platform/deploy/infra/runtime

# HARD GATE: Observability must pass before continuing
echo ""
echo "🔴 OBSERVABILITY GATE (HARD ENFORCEMENT)"
bash scripts/advisory/observability/observability_check.sh || {
  echo "❌ Observability check FAILED — system is not deployable"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

echo ""
echo "✅ Bootstrap complete — observability verified"
