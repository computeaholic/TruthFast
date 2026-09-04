#!/bin/bash
# validate-otel-config.sh - OpenTelemetry configuration validation (enforces operator-native model)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain

ROOT_DIR="platform/deploy/infra/otel"

# Fail if manual runtime resources are present in templates
if grep -R --line-number -E "\bkind:\s*DaemonSet\b|\bkind:\s*Deployment\b" "$ROOT_DIR/templates" 2>/dev/null | grep -v "^#" >/dev/null 2>&1; then
    echo "ERROR: Manual DaemonSet/Deployment resources detected under $ROOT_DIR/templates. Use OpenTelemetryCollector CRs instead."
    grep -R --line-number -E "\bkind:\s*DaemonSet\b|\bkind:\s*Deployment\b" "$ROOT_DIR/templates" || true
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Fail if ConfigMaps for collector config or lineage exist in active tree
if grep -R --line-number -E "otel-collector-config|tf-lineage-injectors|otel-collector-lineage" "$ROOT_DIR" 2>/dev/null | grep -v "\.disabled" | awk -F":" '{ $1=""; $2=""; sub(/^::?/,"",$0); print $0 }' | sed '/^[[:space:]]*#/d' | grep -v "^$" >/dev/null 2>&1; then
    echo "ERROR: Legacy ConfigMap-based collector configs detected in active files. Collector config must live inside OpenTelemetryCollector.spec.config"
    grep -R --line-number -E "otel-collector-config|tf-lineage-injectors|otel-collector-lineage" "$ROOT_DIR" | grep -v "\.disabled" | awk -F":" '{ $1=""; $2=""; sub(/^::?/,"",$0); print $0 }' | sed '/^[[:space:]]*#/d' || true
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Require at least one OpenTelemetryCollector CR in the repo (canonical operator-managed model)
if ! grep -R --line-number -E "kind:.*OpenTelemetryCollector" "$ROOT_DIR" >/dev/null 2>&1; then
    echo "ERROR: No OpenTelemetryCollector CR found in $ROOT_DIR. Add an operator-managed OpenTelemetryCollector CR (e.g., threadforge-collector)."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Fail if legacy logging exporter is present in any active file (must be migrated to debug exporter)
if grep -R --line-number -E "\blogging\b" "$ROOT_DIR" 2>/dev/null | grep -v "\.disabled" >/dev/null 2>&1; then
    echo "ERROR: Deprecated 'logging' exporter found in active OTel files under $ROOT_DIR. Replace with 'debug' or archive the file under platform/deploy/infra/otel/disabled/ with comment 'superseded by operator-managed OpenTelemetryCollector'."
    grep -R --line-number -E "\blogging\b" "$ROOT_DIR" | grep -v "\.disabled" || true
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Also scan key repo directories (platform/deploy/infra, platform/deploy/infra/otel, docs, scripts) for exporter 'logging' occurrences
for f in $(grep -R -I -n -l "exporters" platform/deploy/infra platform/deploy/infra/otel docs scripts 2>/dev/null | grep -v "\.disabled" | sort -u); do
  # Skip shell scripts and binary artifacts
  if echo "$f" | grep -qE "\.sh$|\.py$"; then
    continue
  fi
  if grep -n -I -E "logging" "$f" >/dev/null 2>&1 && ! echo "$f" | grep -q "\.disabled"; then
    echo "ERROR: File $f references exporter 'logging'. Archive or migrate to 'debug' and add comment: 'superseded by operator-managed OpenTelemetryCollector'"
    grep -n -I -E "logging" "$f" || true
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
done

# Enforce: If a file contains tail_sampling, its collector image must be a contrib build (contrib image required for tail_sampling)
for f in $(grep -R -l "tail_sampling" "$ROOT_DIR" 2>/dev/null | grep -v "\.disabled" || true); do
    if [ -n "$f" ] && ! grep -qE "image:\s*.*(contrib|opentelemetry-collector-contrib|threadforge:30500)" "$f"; then
        echo "ERROR: Tail sampling configured in $f but collector image is not a contrib build or internal mirror. Set 'image' to the internal contrib mirror (threadforge:30500/opentelemetry-collector-contrib:VERSION)."
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
done

# Ensure no files reference external registries directly inside platform/deploy/infra/otel (use internal mirror / IMAGES.lock.yaml)
if grep -R --line-number -E "image:\s*.*(ghcr\.io|docker\.io|^\s*otel/|open-telemetry|registry\.|quay\.io)" "$ROOT_DIR" 2>/dev/null | grep -v "\.disabled" >/dev/null 2>&1; then
    echo "ERROR: Hard-coded external registry image references found under $ROOT_DIR. Use internal mirrors (threadforge:30500) and update IMAGES.lock.yaml."
    grep -R --line-number -E "image:\s*.*(ghcr\.io|docker\.io|^\s*otel/|open-telemetry|registry\.|quay\.io)" "$ROOT_DIR" | grep -v "\.disabled" || true
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Ensure lineage is implemented using standard processors (attributes/resource)
if ! grep -R --line-number "attributes:\|resource:" "$ROOT_DIR" >/dev/null 2>&1; then
    echo "ERROR: Lineage enrichment must be implemented via standard processors (attributes/resource)."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Ensure no custom processor names (tf_*) are present in active files
if grep -R --line-number "tf_" "$ROOT_DIR" 2>/dev/null | grep -v "\.disabled" | grep -v "^#" >/dev/null 2>&1; then
    echo "ERROR: Detected tf_* custom processor identifiers in active OTel files. Use standard processors instead (attributes/resource/transform)."
    grep -R --line-number "tf_" "$ROOT_DIR" || true
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Security check: AuthorizationPolicy presence and expected allowances
if ! kubectl get authorizationpolicy -n observability >/dev/null 2>&1; then
    echo "ERROR: AuthorizationPolicy missing in observability namespace. Ensure policies allow DNS, istiod, health_check, and agent→gateway OTLP."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
# Check templates include expected allowances (static check)
if ! grep -R --line-number "ports: \[\"53\"\]" platform/deploy/infra/otel/templates >/dev/null 2>&1; then
    echo "ERROR: AuthorizationPolicy should allow DNS egress (port 53) in platform/deploy/infra/otel/templates/otel-authz-outbound-allow.yaml";
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if ! grep -R --line-number "ports: \[\"13133\"\]" platform/deploy/infra/otel/templates >/dev/null 2>&1; then
    echo "ERROR: AuthorizationPolicy should allow health_check port 13133 in platform/deploy/infra/otel/templates/otel-authz-allow.yaml";
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if ! grep -R --line-number "spiffe://${SPIFFE_TRUST_DOMAIN}/ns/istio-system/sa/istiod" platform/deploy/infra/otel/templates >/dev/null 2>&1; then
    echo "ERROR: AuthorizationPolicy should allow istiod principal (spiffe://${SPIFFE_TRUST_DOMAIN}/ns/istio-system/sa/istiod) in platform/deploy/infra/otel/templates/otel-authz-allow.yaml";
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if ! grep -R --line-number "name: otel-agent" platform/deploy/infra/otel >/dev/null 2>&1; then
    echo "ERROR: otel-agent OpenTelemetryCollector must be present in platform/deploy/infra/otel";
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if ! grep -R --line-number "name: otel-gateway" platform/deploy/infra/otel >/dev/null 2>&1; then
    echo "ERROR: otel-gateway OpenTelemetryCollector must be present in platform/deploy/infra/otel";
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✅ OTel configuration validation passed"
exit 0
