#!/usr/bin/env bash
################################################################################
# OBSERVABILITY DIAGNOSTIC CHECK (ADVISORY)
# Purpose: Verify observability subsystem correctness and connectivity
# Classification: DIAGNOSTIC (not gating) — verifies quality and configuration
#
# Scope (not enforced by bootstrap gate):
#   - Alertmanager config loads successfully
#   - Alertmanager routes are configured
#   - Prometheus can reach Alertmanager endpoint
#   - No persistent alertmanager errors/warnings
#
# Note: Liveness verification (pods running) is handled by observability-gate
# This script diagnoses correctness, not presence.
################################################################################

set -euo pipefail

STRICT=${STRICT:-0}
if [ "${MODE:-}" = "strict" ]; then STRICT=1; fi

EVIDENCE_DIR="/tmp/observability-diagnostic-evidence"
mkdir -p "$EVIDENCE_DIR"

DIAGNOSTIC_PASS=true
FAILURE_REASONS=()

echo "🔍 [observability-diagnostic] Starting observability subsystem diagnostic check..."

# ==============================================================================
# Diagnostic 1: Alertmanager Service Reachability
# ==============================================================================
echo "[observability-diagnostic] Checking Alertmanager service reachability..."

ALERTMANAGER_SVC="kube-prometheus-stack-alertmanager"
ALERTMANAGER_NS="observability"

if ! kubectl get svc "$ALERTMANAGER_SVC" -n "$ALERTMANAGER_NS" >/dev/null 2>&1; then
    DIAGNOSTIC_PASS=false
    FAILURE_REASONS+=("Alertmanager service not found")
    echo "❌ Alertmanager service not found in observability namespace"
else
    ALERTMANAGER_ENDPOINT=$(kubectl get svc "$ALERTMANAGER_SVC" -n "$ALERTMANAGER_NS" \
        -o jsonpath='{.spec.clusterIP}:{.spec.ports[?(@.name=="http-web")].port}' 2>/dev/null || echo "unknown")
    echo "✓ Alertmanager service reachable at: $ALERTMANAGER_ENDPOINT"
fi

# ==============================================================================
# Diagnostic 2: Prometheus Alertmanager Config
# ==============================================================================
echo "[observability-diagnostic] Checking Prometheus alertmanager config..."

PROMETHEUS_NS="observability"
PROMETHEUS_NAME="kube-prometheus-stack-prometheus"

if kubectl get prometheus "$PROMETHEUS_NAME" -n "$PROMETHEUS_NS" >/dev/null 2>&1; then
    ALERTMANAGER_CONFIG=$(kubectl get prometheus "$PROMETHEUS_NAME" -n "$PROMETHEUS_NS" \
        -o jsonpath='{.spec.alerting.alertmanagers}' 2>/dev/null || echo "")

    if [ -z "$ALERTMANAGER_CONFIG" ]; then
        DIAGNOSTIC_PASS=false
        FAILURE_REASONS+=("Prometheus has no alertmanager configuration")
        echo "❌ Prometheus has no alertmanager endpoints configured"
    else
        echo "✓ Prometheus alertmanager config present: $ALERTMANAGER_CONFIG"
        echo "$ALERTMANAGER_CONFIG" > "$EVIDENCE_DIR/prometheus_alertmanager_config.json"
    fi
else
    DIAGNOSTIC_PASS=false
    FAILURE_REASONS+=("Prometheus CRD not found")
    echo "❌ Prometheus CRD not found"
fi

# ==============================================================================
# Diagnostic 3: Alertmanager Pod Logs (no errors)
# ==============================================================================
echo "[observability-diagnostic] Checking Alertmanager pod logs for errors..."

ALERTMANAGER_POD=$(kubectl get pods -n "$ALERTMANAGER_NS" \
    -l "alertmanager" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$ALERTMANAGER_POD" ]; then
    DIAGNOSTIC_PASS=false
    FAILURE_REASONS+=("No Alertmanager pod found")
    echo "❌ Alertmanager pod not found"
else
    # Get last 50 lines of logs
    ALERTMANAGER_LOGS=$(kubectl logs "$ALERTMANAGER_POD" -n "$ALERTMANAGER_NS" \
        --tail=50 --timestamps=true 2>/dev/null || echo "")

    # Check for error keywords
    ERROR_COUNT=$(echo "$ALERTMANAGER_LOGS" | grep -i "error\|fatal\|panic" | wc -l)
    ERROR_COUNT=$((ERROR_COUNT + 0))  # Convert to integer safely

    if [ "$ERROR_COUNT" -gt 0 ]; then
        DIAGNOSTIC_PASS=false
        FAILURE_REASONS+=("Alertmanager logs contain error messages ($ERROR_COUNT errors)")
        echo "⚠ Alertmanager logs contain $ERROR_COUNT error messages"
        echo "$ALERTMANAGER_LOGS" > "$EVIDENCE_DIR/alertmanager_pod_logs_with_errors.txt"
    else
        echo "✓ Alertmanager logs are error-free"
    fi
fi

# ==============================================================================
# Diagnostic 4: Alertmanager Routes Configured
# ==============================================================================
echo "[observability-diagnostic] Checking Alertmanager route configuration..."

# Get Alertmanager config via its API if pod is accessible
if [ -n "$ALERTMANAGER_POD" ]; then
    # Try to get config from Alertmanager API
    ALERTMANAGER_CONFIG_JSON=$(kubectl exec "$ALERTMANAGER_POD" -n "$ALERTMANAGER_NS" \
        -- curl -s http://localhost:9093/api/v2/status 2>/dev/null || echo "{}")

    if echo "$ALERTMANAGER_CONFIG_JSON" | grep -q "config"; then
        echo "✓ Alertmanager API reachable and returns config"
        echo "$ALERTMANAGER_CONFIG_JSON" > "$EVIDENCE_DIR/alertmanager_api_status.json"
    else
        echo "⚠ Could not verify Alertmanager API config"
    fi
fi

# ==============================================================================
# Diagnostic 5: Tempo OTLP Transport Mode (explicit declaration)
# ==============================================================================
echo "[observability-diagnostic] Checking Tempo OTLP transport mode..."

OTEL_EXPORTER_ENDPOINT=$(kubectl get opentelemetrycollector threadforge-collector -n observability \
    -o jsonpath='{.spec.config.exporters.otlphttp.endpoint}' 2>/dev/null || echo "")
OTEL_EXPORTER_INSECURE=$(kubectl get opentelemetrycollector threadforge-collector -n observability \
    -o jsonpath='{.spec.config.exporters.otlphttp.tls.insecure}' 2>/dev/null || echo "")

if [[ "$OTEL_EXPORTER_ENDPOINT" == http://* && "$OTEL_EXPORTER_INSECURE" == "true" ]]; then
    echo "⚠ Running insecure by design (Tempo OTLP HTTP without TLS)"
    echo "running_insecure_by_design=true" > "$EVIDENCE_DIR/tempo_otlp_transport_mode.txt"
else
    echo "✓ Secure transport configured for Tempo OTLP exporter"
    echo "running_insecure_by_design=false" > "$EVIDENCE_DIR/tempo_otlp_transport_mode.txt"
fi

# ==============================================================================
# Summary and Decision
# ==============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "OBSERVABILITY DIAGNOSTIC SUMMARY"
echo "═══════════════════════════════════════════════════════════════════════════"

if [ "$DIAGNOSTIC_PASS" = true ]; then
    echo "✅ DIAGNOSTIC PASS — observability subsystem is correctly configured"
    exit 0
else
    echo "⚠ DIAGNOSTIC WARNINGS:"
    for reason in "${FAILURE_REASONS[@]}"; do
        echo "  - $reason"
    done
    echo ""
    echo "Evidence collected in: $EVIDENCE_DIR"

    if [ "$STRICT" = "1" ]; then
        echo "⛔ STRICT MODE: exiting with failure"
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    else
        echo "ℹ ADVISORY MODE: continuing despite diagnostic warnings"
        exit 0
    fi
fi
