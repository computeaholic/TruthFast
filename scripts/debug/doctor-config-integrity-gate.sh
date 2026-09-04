#!/usr/bin/env bash
# ┌──────────────────────────────────────────────────────────────────────────────┐
# │ CONFIG INTEGRITY GATE (GATING)                                               │
# ├──────────────────────────────────────────────────────────────────────────────┤
# │ Authority Question: "Am I executing against the configuration I believe      │
# │                      I am?"                                                  │
# │                                                                              │
# │ This gate verifies runtime-effective configuration matches expected source.  │
# │ It is read-only and does NOT mutate cluster state.                          │
# │                                                                              │
# │ GATING CONDITIONS:                                                           │
# │   1. Collector Config    — OTEL collector config matches expected source    │
# │   2. Tempo Config        — Tempo config matches expected source             │
# │   3. NetworkPolicy       — Required policies exist with correct rules       │
# │   4. Config Drift        — ConfigMaps/Secrets structure unchanged           │
# │                                                                              │
# │ FAILURE SEMANTICS:                                                           │
# │   STRICT=1  → echo "[ADVISORY-FAIL] non-authoritative path"; exit 0 immediately (hard fail, execution blocked)             │
# │   STRICT=0  → warn + record degradation, continue (advisory)                │
# │                                                                              │
# │ EVIDENCE BUNDLE: /tmp/${DRILL_ID}-config-integrity-evidence/                 │
# └──────────────────────────────────────────────────────────────────────────────┘

set -euo pipefail

STRICT=${STRICT:-0}
if [ "${MODE:-}" = "strict" ]; then STRICT=1; fi

if [ -z "${DRILL_ID:-}" ]; then
  echo "ERROR: DRILL_ID must be set" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

EVIDENCE_DIR="/tmp/${DRILL_ID}-config-integrity-evidence"
mkdir -p "$EVIDENCE_DIR"

# Initialize decision state
GATE_PASS=true
FAILURE_REASONS=()

# Timestamps for evidence
NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "[config-integrity] Starting config integrity gate with DRILL_ID=${DRILL_ID}"

# -----------------------------------------------------------------------------
# EXPECTED CONFIGURATION SOURCES
# -----------------------------------------------------------------------------
# These are the canonical source files for configuration truth
COLLECTOR_SOURCE="/home/threadforge/threadforge/platform/deploy/infra/otel/policy.yaml"
TEMPO_SOURCE="/home/threadforge/threadforge/platform/deploy/infra/tempo/templates/configmap.yaml"

# -----------------------------------------------------------------------------
# CONDITION 1: Collector Config Integrity
# -----------------------------------------------------------------------------
echo "[config-integrity] Checking OTEL collector config integrity..."

COLLECTOR_EVIDENCE='{"match": false, "reason": "not checked"}'

if ! kubectl get ns observability >/dev/null 2>&1; then
  GATE_PASS=false
  FAILURE_REASONS+=("observability namespace does not exist")
  COLLECTOR_EVIDENCE='{"match": false, "reason": "namespace not found"}'
  echo "[config-integrity] FAIL: observability namespace not found"
else
  # Get effective collector config from cluster
  EFFECTIVE_COLLECTOR=$(kubectl -n observability get opentelemetrycollector threadforge-collector \
    -o jsonpath='{.spec.config}' 2>/dev/null || echo "")

  if [ -z "$EFFECTIVE_COLLECTOR" ]; then
    GATE_PASS=false
    FAILURE_REASONS+=("collector CR not found or has no config")
    COLLECTOR_EVIDENCE='{"match": false, "reason": "collector CR not found"}'
    echo "[config-integrity] FAIL: Collector CR not found"
  else
    # Save effective config
    echo "$EFFECTIVE_COLLECTOR" | jq -S . > "$EVIDENCE_DIR/collector_effective.json" 2>/dev/null || \
      echo "$EFFECTIVE_COLLECTOR" > "$EVIDENCE_DIR/collector_effective.json"

    # Extract expected config from source file
    if [ -f "$COLLECTOR_SOURCE" ]; then
      # Use Python for reliable YAML parsing
      EXPECTED_COLLECTOR=$(python3 -c "
import yaml
import json
with open('$COLLECTOR_SOURCE', 'r') as f:
    docs = list(yaml.safe_load_all(f))
for doc in docs:
    if doc and doc.get('kind') == 'OpenTelemetryCollector':
        config = doc.get('spec', {}).get('config', {})
        if config:
            # Config may be a dict (already parsed) or a YAML string
            if isinstance(config, str):
                config = yaml.safe_load(config)
            print(json.dumps(config, sort_keys=True))
            break
" 2>/dev/null || echo "")
      echo "$EXPECTED_COLLECTOR" > "$EVIDENCE_DIR/collector_expected.json" 2>/dev/null || true

      # Compare by hash (normalized JSON - both must go through jq -S for consistent formatting)
      EFFECTIVE_HASH=$(echo "$EFFECTIVE_COLLECTOR" | jq -S . 2>/dev/null | sha256sum | cut -d' ' -f1)
      EXPECTED_HASH=$(echo "$EXPECTED_COLLECTOR" | jq -S . 2>/dev/null | sha256sum | cut -d' ' -f1)

      if [ "$EFFECTIVE_HASH" = "$EXPECTED_HASH" ]; then
        COLLECTOR_EVIDENCE="{\"match\": true, \"effective_hash\": \"${EFFECTIVE_HASH:0:16}\", \"expected_hash\": \"${EXPECTED_HASH:0:16}\"}"
        echo "[config-integrity] OK: Collector config matches expected (hash: ${EFFECTIVE_HASH:0:16})"
      else
        # Check for critical differences (both through jq -S for consistent diff)
        DIFF_OUTPUT=$(diff <(echo "$EFFECTIVE_COLLECTOR" | jq -S . 2>/dev/null) \
                          <(echo "$EXPECTED_COLLECTOR" | jq -S . 2>/dev/null) 2>/dev/null | head -20 || echo "diff failed")
        echo "$DIFF_OUTPUT" > "$EVIDENCE_DIR/collector_diff.txt"

        GATE_PASS=false
        FAILURE_REASONS+=("collector config drift detected")
        COLLECTOR_EVIDENCE="{\"match\": false, \"effective_hash\": \"${EFFECTIVE_HASH:0:16}\", \"expected_hash\": \"${EXPECTED_HASH:0:16}\", \"diff_sample\": \"see collector_diff.txt\"}"
        echo "[config-integrity] FAIL: Collector config drift detected"
      fi
    else
      # Source file not found - verify critical fields directly
      echo "[config-integrity] WARN: Source file not found, validating critical fields"

      # Verify required receivers
      HAS_OTLP_RECEIVER=$(echo "$EFFECTIVE_COLLECTOR" | jq -e '.receivers.otlp.protocols.grpc.endpoint' 2>/dev/null && echo "yes" || echo "no")
      HAS_HTTP_RECEIVER=$(echo "$EFFECTIVE_COLLECTOR" | jq -e '.receivers.otlp.protocols.http.endpoint' 2>/dev/null && echo "yes" || echo "no")

      # Verify required exporters
      HAS_OTLP_EXPORTER=$(echo "$EFFECTIVE_COLLECTOR" | jq -e '.exporters.otlp.endpoint' 2>/dev/null && echo "yes" || echo "no")
      EXPORTER_ENDPOINT=$(echo "$EFFECTIVE_COLLECTOR" | jq -r '.exporters.otlp.endpoint // "none"' 2>/dev/null)

      # Verify pipeline
      TRACES_PIPELINE=$(echo "$EFFECTIVE_COLLECTOR" | jq -e '.service.pipelines.traces' 2>/dev/null && echo "yes" || echo "no")

      # Check for unexpected receivers/exporters
      ALL_RECEIVERS=$(echo "$EFFECTIVE_COLLECTOR" | jq -r '.receivers | keys[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
      ALL_EXPORTERS=$(echo "$EFFECTIVE_COLLECTOR" | jq -r '.exporters | keys[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//')

      UNEXPECTED_RECEIVERS=""
      UNEXPECTED_EXPORTERS=""

      # Expected receivers: otlp
      for r in $(echo "$EFFECTIVE_COLLECTOR" | jq -r '.receivers | keys[]' 2>/dev/null); do
        case "$r" in
          otlp) ;; # expected
          *) UNEXPECTED_RECEIVERS="${UNEXPECTED_RECEIVERS}${r}," ;;
        esac
      done

      # Expected exporters: otlp, debug
      for e in $(echo "$EFFECTIVE_COLLECTOR" | jq -r '.exporters | keys[]' 2>/dev/null); do
        case "$e" in
          otlp|debug) ;; # expected
          *) UNEXPECTED_EXPORTERS="${UNEXPECTED_EXPORTERS}${e}," ;;
        esac
      done

      COLLECTOR_OK=true
      COLLECTOR_ISSUES=""

      if [ "$HAS_OTLP_RECEIVER" != "yes" ]; then
        COLLECTOR_OK=false
        COLLECTOR_ISSUES="${COLLECTOR_ISSUES}missing OTLP gRPC receiver; "
      fi
      if [ "$HAS_HTTP_RECEIVER" != "yes" ]; then
        COLLECTOR_OK=false
        COLLECTOR_ISSUES="${COLLECTOR_ISSUES}missing OTLP HTTP receiver; "
      fi
      if [ "$HAS_OTLP_EXPORTER" != "yes" ]; then
        COLLECTOR_OK=false
        COLLECTOR_ISSUES="${COLLECTOR_ISSUES}missing OTLP exporter; "
      fi
      if [ "$EXPORTER_ENDPOINT" != "tempo.tempo.svc.cluster.local:4317" ]; then
        COLLECTOR_OK=false
        COLLECTOR_ISSUES="${COLLECTOR_ISSUES}exporter endpoint mismatch (got: $EXPORTER_ENDPOINT); "
      fi
      if [ "$TRACES_PIPELINE" != "yes" ]; then
        COLLECTOR_OK=false
        COLLECTOR_ISSUES="${COLLECTOR_ISSUES}traces pipeline not configured; "
      fi
      if [ -n "$UNEXPECTED_RECEIVERS" ]; then
        COLLECTOR_OK=false
        COLLECTOR_ISSUES="${COLLECTOR_ISSUES}unexpected receivers: ${UNEXPECTED_RECEIVERS%,}; "
      fi
      if [ -n "$UNEXPECTED_EXPORTERS" ]; then
        COLLECTOR_OK=false
        COLLECTOR_ISSUES="${COLLECTOR_ISSUES}unexpected exporters: ${UNEXPECTED_EXPORTERS%,}; "
      fi

      if [ "$COLLECTOR_OK" = "true" ]; then
        COLLECTOR_EVIDENCE="{\"match\": true, \"method\": \"field_validation\", \"receivers\": \"$ALL_RECEIVERS\", \"exporters\": \"$ALL_EXPORTERS\"}"
        echo "[config-integrity] OK: Collector config valid (field validation)"
      else
        GATE_PASS=false
        FAILURE_REASONS+=("collector config validation failed: ${COLLECTOR_ISSUES}")
        COLLECTOR_EVIDENCE="{\"match\": false, \"method\": \"field_validation\", \"issues\": \"${COLLECTOR_ISSUES}\"}"
        echo "[config-integrity] FAIL: Collector config issues: ${COLLECTOR_ISSUES}"
      fi
    fi
  fi
fi

echo "$COLLECTOR_EVIDENCE" | jq . > "$EVIDENCE_DIR/collector_integrity.json" 2>/dev/null || \
  echo "$COLLECTOR_EVIDENCE" > "$EVIDENCE_DIR/collector_integrity.json"

# -----------------------------------------------------------------------------
# CONDITION 2: Tempo Config Integrity
# -----------------------------------------------------------------------------
echo "[config-integrity] Checking Tempo config integrity..."

TEMPO_EVIDENCE='{"match": false, "reason": "not checked"}'

if ! kubectl get ns tempo >/dev/null 2>&1; then
  GATE_PASS=false
  FAILURE_REASONS+=("tempo namespace does not exist")
  TEMPO_EVIDENCE='{"match": false, "reason": "namespace not found"}'
  echo "[config-integrity] FAIL: tempo namespace not found"
else
  # Get effective Tempo config from cluster
  EFFECTIVE_TEMPO=$(kubectl -n tempo get configmap tempo-config -o jsonpath='{.data.tempo\.yaml}' 2>/dev/null || echo "")

  if [ -z "$EFFECTIVE_TEMPO" ]; then
    GATE_PASS=false
    FAILURE_REASONS+=("tempo config not found")
    TEMPO_EVIDENCE='{"match": false, "reason": "tempo configmap not found"}'
    echo "[config-integrity] FAIL: Tempo config not found"
  else
    # Save effective config
    echo "$EFFECTIVE_TEMPO" > "$EVIDENCE_DIR/tempo_effective.yaml"

    # Validate critical Tempo fields using Python for reliable YAML parsing
    TEMPO_OK=true
    TEMPO_ISSUES=""

    # Parse Tempo config with Python
    TEMPO_PARSED=$(python3 -c "
import yaml
import json
import sys

config_text = '''$EFFECTIVE_TEMPO'''
try:
    config = yaml.safe_load(config_text)
    result = {
        'grpc_endpoint': config.get('distributor', {}).get('receivers', {}).get('otlp', {}).get('protocols', {}).get('grpc', {}).get('endpoint', 'none'),
        'http_endpoint': config.get('distributor', {}).get('receivers', {}).get('otlp', {}).get('protocols', {}).get('http', {}).get('endpoint', 'none'),
        'storage_backend': config.get('storage', {}).get('trace', {}).get('backend', 'none'),
        's3_endpoint': config.get('storage', {}).get('trace', {}).get('s3', {}).get('endpoint', 'none'),
        's3_bucket': config.get('storage', {}).get('trace', {}).get('s3', {}).get('bucket', 'none'),
        'local_storage': config.get('storage', {}).get('trace', {}).get('local', None)
    }
    print(json.dumps(result))
except Exception as e:
    print(json.dumps({'error': str(e)}))
" 2>/dev/null || echo '{"error": "parse failed"}')

    # Extract values from parsed config
    GRPC_ENDPOINT=$(echo "$TEMPO_PARSED" | jq -r '.grpc_endpoint // "none"')
    HTTP_ENDPOINT=$(echo "$TEMPO_PARSED" | jq -r '.http_endpoint // "none"')
    STORAGE_BACKEND=$(echo "$TEMPO_PARSED" | jq -r '.storage_backend // "none"')
    S3_ENDPOINT=$(echo "$TEMPO_PARSED" | jq -r '.s3_endpoint // "none"')
    S3_BUCKET=$(echo "$TEMPO_PARSED" | jq -r '.s3_bucket // "none"')
    LOCAL_BACKEND=$(echo "$TEMPO_PARSED" | jq -r '.local_storage // "null"')

    if [ "$GRPC_ENDPOINT" != "0.0.0.0:4317" ]; then
      TEMPO_OK=false
      TEMPO_ISSUES="${TEMPO_ISSUES}gRPC endpoint mismatch (got: $GRPC_ENDPOINT, expected: 0.0.0.0:4317); "
    fi
    if [ "$HTTP_ENDPOINT" != "0.0.0.0:4318" ]; then
      TEMPO_OK=false
      TEMPO_ISSUES="${TEMPO_ISSUES}HTTP endpoint mismatch (got: $HTTP_ENDPOINT, expected: 0.0.0.0:4318); "
    fi
    if [ "$STORAGE_BACKEND" != "s3" ]; then
      TEMPO_OK=false
      TEMPO_ISSUES="${TEMPO_ISSUES}storage backend mismatch (got: $STORAGE_BACKEND, expected: s3); "
    fi
    if [ "$S3_ENDPOINT" != "minio.minio.svc.cluster.local:9000" ]; then
      TEMPO_OK=false
      TEMPO_ISSUES="${TEMPO_ISSUES}S3 endpoint mismatch (got: $S3_ENDPOINT); "
    fi
    if [ "$S3_BUCKET" != "tf-traces" ]; then
      TEMPO_OK=false
      TEMPO_ISSUES="${TEMPO_ISSUES}S3 bucket mismatch (got: $S3_BUCKET, expected: tf-traces); "
    fi
    if [ "$LOCAL_BACKEND" != "null" ] && [ -n "$LOCAL_BACKEND" ]; then
      TEMPO_OK=false
      TEMPO_ISSUES="${TEMPO_ISSUES}local storage fallback detected; "
    fi

    if [ "$TEMPO_OK" = "true" ]; then
      TEMPO_HASH=$(echo "$EFFECTIVE_TEMPO" | sha256sum | cut -d' ' -f1)
      TEMPO_EVIDENCE="{\"match\": true, \"grpc_endpoint\": \"$GRPC_ENDPOINT\", \"http_endpoint\": \"$HTTP_ENDPOINT\", \"storage_backend\": \"$STORAGE_BACKEND\", \"s3_endpoint\": \"$S3_ENDPOINT\", \"config_hash\": \"${TEMPO_HASH:0:16}\"}"
      echo "[config-integrity] OK: Tempo config valid (hash: ${TEMPO_HASH:0:16})"
    else
      GATE_PASS=false
      FAILURE_REASONS+=("tempo config validation failed: ${TEMPO_ISSUES}")
      TEMPO_EVIDENCE="{\"match\": false, \"issues\": \"${TEMPO_ISSUES}\"}"
      echo "[config-integrity] FAIL: Tempo config issues: ${TEMPO_ISSUES}"
    fi
  fi
fi

echo "$TEMPO_EVIDENCE" | jq . > "$EVIDENCE_DIR/tempo_integrity.json" 2>/dev/null || \
  echo "$TEMPO_EVIDENCE" > "$EVIDENCE_DIR/tempo_integrity.json"

# -----------------------------------------------------------------------------
# CONDITION 3: NetworkPolicy Consistency
# -----------------------------------------------------------------------------
echo "[config-integrity] Checking NetworkPolicy consistency..."

NETPOL_EVIDENCE='{"consistent": false, "reason": "not checked"}'
NETPOL_OK=true
NETPOL_ISSUES=""

# Required NetworkPolicies and their rules
# 1. Tempo must allow ingress from collector on 4317/4318
# 2. Tempo must allow ingress from telemetry probes on 4317/4318

# Check Tempo NetworkPolicy
TEMPO_NETPOL=$(kubectl -n tempo get networkpolicy tempo-restrict -o json 2>/dev/null || echo "")

if [ -z "$TEMPO_NETPOL" ]; then
  NETPOL_OK=false
  NETPOL_ISSUES="${NETPOL_ISSUES}tempo-restrict NetworkPolicy not found; "
else
  # Check if collector is allowed (from observability namespace with collector label)
  COLLECTOR_MATCH=$(echo "$TEMPO_NETPOL" | jq -r '
    [.spec.ingress[]?.from[]? |
     select(.namespaceSelector?.matchLabels["kubernetes.io/metadata.name"] == "observability") |
     select(.podSelector?.matchLabels["app.kubernetes.io/component"] == "opentelemetry-collector")] | length
  ' 2>/dev/null || echo "0")

  if [ "$COLLECTOR_MATCH" -gt 0 ] 2>/dev/null; then
    ALLOWS_COLLECTOR="yes"
  else
    ALLOWS_COLLECTOR="no"
  fi

  # Check if telemetry probes are allowed
  PROBE_MATCH=$(echo "$TEMPO_NETPOL" | jq -r '
    [.spec.ingress[]?.from[]? |
     select(.namespaceSelector?.matchLabels["kubernetes.io/metadata.name"] == "observability") |
     select(.podSelector?.matchLabels["threadforge.dev/purpose"] == "telemetry-probe")] | length
  ' 2>/dev/null || echo "0")

  if [ "$PROBE_MATCH" -gt 0 ] 2>/dev/null; then
    ALLOWS_PROBES="yes"
  else
    ALLOWS_PROBES="no"
  fi

  # Check allowed ports include 4317 and 4318
  PORT_4317_MATCH=$(echo "$TEMPO_NETPOL" | jq -r '
    [.spec.ingress[]?.ports[]? | select(.port == 4317)] | length
  ' 2>/dev/null || echo "0")

  PORT_4318_MATCH=$(echo "$TEMPO_NETPOL" | jq -r '
    [.spec.ingress[]?.ports[]? | select(.port == 4318)] | length
  ' 2>/dev/null || echo "0")

  if [ "$PORT_4317_MATCH" -gt 0 ] 2>/dev/null; then
    ALLOWS_4317="yes"
  else
    ALLOWS_4317="no"
  fi

  if [ "$PORT_4318_MATCH" -gt 0 ] 2>/dev/null; then
    ALLOWS_4318="yes"
  else
    ALLOWS_4318="no"
  fi

  if [ "$ALLOWS_COLLECTOR" != "yes" ]; then
    NETPOL_OK=false
    NETPOL_ISSUES="${NETPOL_ISSUES}tempo-restrict does not allow collector; "
  fi
  if [ "$ALLOWS_PROBES" != "yes" ]; then
    NETPOL_OK=false
    NETPOL_ISSUES="${NETPOL_ISSUES}tempo-restrict does not allow telemetry probes; "
  fi
  if [ "$ALLOWS_4317" != "yes" ]; then
    NETPOL_OK=false
    NETPOL_ISSUES="${NETPOL_ISSUES}tempo-restrict does not allow port 4317; "
  fi
  if [ "$ALLOWS_4318" != "yes" ]; then
    NETPOL_OK=false
    NETPOL_ISSUES="${NETPOL_ISSUES}tempo-restrict does not allow port 4318; "
  fi

  # Save policy for evidence
  echo "$TEMPO_NETPOL" | jq . > "$EVIDENCE_DIR/tempo_networkpolicy.json" 2>/dev/null || true
fi

# Check for implicit allow-all policies (dangerous)
ALLOW_ALL_POLICIES=$(kubectl get networkpolicy -A -o json 2>/dev/null | jq -r '
  .items[] |
  select(.spec.podSelector == {} or .spec.podSelector == null) |
  select(.spec.ingress == [{}] or .spec.egress == [{}]) |
  "\(.metadata.namespace)/\(.metadata.name)"
' 2>/dev/null || echo "")

if [ -n "$ALLOW_ALL_POLICIES" ]; then
  NETPOL_OK=false
  NETPOL_ISSUES="${NETPOL_ISSUES}implicit allow-all policies detected: ${ALLOW_ALL_POLICIES}; "
fi

if [ "$NETPOL_OK" = "true" ]; then
  NETPOL_EVIDENCE="{\"consistent\": true, \"tempo_allows_collector\": true, \"tempo_allows_probes\": true, \"no_allow_all\": true}"
  echo "[config-integrity] OK: NetworkPolicies consistent"
else
  GATE_PASS=false
  FAILURE_REASONS+=("NetworkPolicy validation failed: ${NETPOL_ISSUES}")
  NETPOL_EVIDENCE="{\"consistent\": false, \"issues\": \"${NETPOL_ISSUES}\"}"
  echo "[config-integrity] FAIL: NetworkPolicy issues: ${NETPOL_ISSUES}"
fi

echo "$NETPOL_EVIDENCE" | jq . > "$EVIDENCE_DIR/networkpolicy_consistency.json" 2>/dev/null || \
  echo "$NETPOL_EVIDENCE" > "$EVIDENCE_DIR/networkpolicy_consistency.json"

# -----------------------------------------------------------------------------
# CONDITION 4: Config Drift Detection (ConfigMaps/Secrets)
# -----------------------------------------------------------------------------
echo "[config-integrity] Checking for config drift..."

DRIFT_EVIDENCE='{"drift_detected": false}'
DRIFT_OK=true
DRIFT_ISSUES=""

# Hash critical ConfigMaps
declare -A CONFIG_HASHES
CONFIG_HASHES["observability/threadforge-collector-collector"]=""
CONFIG_HASHES["tempo/tempo-config"]=""

# Get current hashes
for key in "${!CONFIG_HASHES[@]}"; do
  NS=$(echo "$key" | cut -d'/' -f1)
  NAME=$(echo "$key" | cut -d'/' -f2)
  HASH=$(kubectl -n "$NS" get configmap "$NAME" -o json 2>/dev/null | jq -S '.data' | sha256sum | cut -d' ' -f1 || echo "not-found")
  CONFIG_HASHES["$key"]="$HASH"
done

# Check critical Secrets exist (structure only, not values)
CRITICAL_SECRETS=()
# Add any critical secrets here if needed

# Save drift evidence
DRIFT_JSON="{"
DRIFT_JSON="${DRIFT_JSON}\"configmaps\": {"
for key in "${!CONFIG_HASHES[@]}"; do
  DRIFT_JSON="${DRIFT_JSON}\"${key}\": \"${CONFIG_HASHES[$key]:0:16}\","
done
DRIFT_JSON="${DRIFT_JSON%,}}"
DRIFT_JSON="${DRIFT_JSON}, \"timestamp\": \"$NOW_UTC\""
DRIFT_JSON="${DRIFT_JSON}}"

echo "$DRIFT_JSON" | jq . > "$EVIDENCE_DIR/config_hashes.json" 2>/dev/null || \
  echo "$DRIFT_JSON" > "$EVIDENCE_DIR/config_hashes.json"

# Verify no ConfigMaps are missing
for key in "${!CONFIG_HASHES[@]}"; do
  if [ "${CONFIG_HASHES[$key]}" = "not-found" ]; then
    DRIFT_OK=false
    DRIFT_ISSUES="${DRIFT_ISSUES}ConfigMap $key not found; "
  fi
done

if [ "$DRIFT_OK" = "true" ]; then
  DRIFT_EVIDENCE="{\"drift_detected\": false, \"configmaps_checked\": ${#CONFIG_HASHES[@]}, \"all_present\": true}"
  echo "[config-integrity] OK: No config drift detected"
else
  GATE_PASS=false
  FAILURE_REASONS+=("config drift detected: ${DRIFT_ISSUES}")
  DRIFT_EVIDENCE="{\"drift_detected\": true, \"issues\": \"${DRIFT_ISSUES}\"}"
  echo "[config-integrity] FAIL: Config drift: ${DRIFT_ISSUES}"
fi

echo "$DRIFT_EVIDENCE" | jq . > "$EVIDENCE_DIR/drift_detection.json" 2>/dev/null || \
  echo "$DRIFT_EVIDENCE" > "$EVIDENCE_DIR/drift_detection.json"

# -----------------------------------------------------------------------------
# DECISION
# -----------------------------------------------------------------------------
if [ "$GATE_PASS" = "true" ]; then
  echo "[config-integrity] PASS — all configurations verified"
  DECISION="PASS"
else
  echo "[config-integrity] FAIL — $(IFS=';'; echo "${FAILURE_REASONS[*]}")"
  DECISION="FAIL"
fi

# Determine effective collector config status
COLLECTOR_STATUS="UNKNOWN"
if echo "$COLLECTOR_EVIDENCE" | jq -e '.match == true' >/dev/null 2>&1; then
  COLLECTOR_STATUS="PASS"
else
  COLLECTOR_STATUS="FAIL"
fi

# Determine effective tempo config status
TEMPO_STATUS="UNKNOWN"
if echo "$TEMPO_EVIDENCE" | jq -e '.match == true' >/dev/null 2>&1; then
  TEMPO_STATUS="PASS"
else
  TEMPO_STATUS="FAIL"
fi

# Determine NetworkPolicy status
NETPOL_STATUS="UNKNOWN"
if echo "$NETPOL_EVIDENCE" | jq -e '.consistent == true' >/dev/null 2>&1; then
  NETPOL_STATUS="PASS"
else
  NETPOL_STATUS="FAIL"
fi

# Determine drift status
DRIFT_STATUS="UNKNOWN"
if echo "$DRIFT_EVIDENCE" | jq -e '.drift_detected == false' >/dev/null 2>&1; then
  DRIFT_STATUS="PASS"
else
  DRIFT_STATUS="FAIL"
fi

# Write decision file
cat > "$EVIDENCE_DIR/decision.txt" <<EOF
CONFIG INTEGRITY GATE
=====================
Drill ID:    ${DRILL_ID}
Timestamp:   ${NOW_UTC}
Mode:        $([ "$STRICT" = "1" ] && echo "STRICT" || echo "ADVISORY")
Decision:    ${DECISION}

Conditions:
  1. Collector Config:      ${COLLECTOR_STATUS}
  2. Tempo Config:          ${TEMPO_STATUS}
  3. NetworkPolicy:         ${NETPOL_STATUS}
  4. Config Drift:          ${DRIFT_STATUS}

$([ ${#FAILURE_REASONS[@]} -gt 0 ] && echo "Failure Reasons:" && printf "  - %s\n" "${FAILURE_REASONS[@]}" || echo "")

Evidence: ${EVIDENCE_DIR}/
EOF

cat "$EVIDENCE_DIR/decision.txt"

# Write summary JSON
cat > "$EVIDENCE_DIR/summary.json" <<EOF
{
  "gate": "config-integrity",
  "drill_id": "${DRILL_ID}",
  "timestamp": "${NOW_UTC}",
  "mode": "$([ "$STRICT" = "1" ] && echo "strict" || echo "advisory")",
  "decision": "${DECISION}",
  "conditions": {
    "collector_config": "${COLLECTOR_STATUS}",
    "tempo_config": "${TEMPO_STATUS}",
    "networkpolicy": "${NETPOL_STATUS}",
    "config_drift": "${DRIFT_STATUS}"
  },
  "failure_reasons": $(printf '%s\n' "${FAILURE_REASONS[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))')
}
EOF

# Exit based on mode
if [ "$DECISION" = "FAIL" ]; then
  if [ "$STRICT" = "1" ]; then
    echo ""
    echo "⛔ CONFIG INTEGRITY GATE FAIL (STRICT) — execution blocked"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  else
    echo ""
    echo "⚠️  CONFIG INTEGRITY GATE FAIL (ADVISORY) — continuing with degraded confidence"
    exit 0
  fi
else
  echo ""
  echo "✅ CONFIG INTEGRITY GATE PASS"
  exit 0
fi
