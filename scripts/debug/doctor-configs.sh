#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Verifying critical config objects…"
if ! kubectl get ns observability >/dev/null 2>&1; then
  echo "⚠️  Observability configs skipped (namespace absent)"
  exit 0
fi

if kubectl get configmap grafana-datasources -n observability >/dev/null 2>&1; then
  echo "✔ Grafana datasources config present"
else
  echo "⚠️  Missing Grafana datasources config"
fi

if kubectl get opentelemetrycollector -n observability >/dev/null 2>&1; then
  echo "✔ OpenTelemetryCollector CRs present"
else
  echo "⚠️  Missing OpenTelemetryCollector CRs (otel-agent, otel-gateway)"
fi

# Run static OTel validation script (non-fatally reported)
if bash scripts/validate-otel-config.sh >/dev/null 2>&1; then
  echo "✔ OTel validation script passed"
else
  echo "⚠️  OTel validation script reported an issue"; rc=1
fi

# If any critical failures, exit non-zero
if [ "${rc-0}" != "0" ]; then
  exit 2
fi

echo "🔍 Critical config verification complete"
exit 0
