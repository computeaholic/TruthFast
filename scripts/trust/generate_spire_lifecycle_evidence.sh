#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${SPIRE_LIFECYCLE_EVIDENCE_DIR:-$REPO_ROOT/artifacts/trust/spire_lifecycle}"
NAMESPACE="${SPIRE_NAMESPACE:-spire-system}"
POD="${SPIRE_SERVER_POD:-spire-server-0}"
SPIRE_SERVER_BIN="${SPIRE_SERVER_BIN:-/opt/spire/bin/spire-server}"
SPIRE_SOCKET="${SPIRE_SOCKET:-/run/spire/private/spire-server.sock}"

mkdir -p "$OUT_DIR" "$REPO_ROOT/artifacts/trust"

bundle_file="$OUT_DIR/spire_bundle.pem"
config_file="$OUT_DIR/spire_server_config.hcl"
logs_file="$OUT_DIR/spire_server_lifecycle.log"
metrics_file="$OUT_DIR/spire_server_metrics.prom"
status_file="$REPO_ROOT/artifacts/trust/root_lifecycle_status.json"
status_metrics_file="$REPO_ROOT/artifacts/trust/root_lifecycle_metrics.prom"

kubectl -n "$NAMESPACE" exec "$POD" -- "$SPIRE_SERVER_BIN" bundle show \
  -socketPath "$SPIRE_SOCKET" \
  -format pem >"$bundle_file"

kubectl -n "$NAMESPACE" get cm spire-server-config \
  -o 'jsonpath={.data.server\.conf}' >"$config_file" 2>/dev/null || true

kubectl -n "$NAMESPACE" logs "$POD" -c spire-server --since="${SPIRE_LIFECYCLE_LOG_SINCE:-48h}" \
  | grep -E 'X509 CA (prepared|activated)|local_authority_id|bundle|authority|upstream' >"$logs_file" || true

if kubectl -n "$NAMESPACE" port-forward "pod/$POD" 19091:9091 >/tmp/threadforge-spire-metrics-port-forward.log 2>&1 &
then
  pf_pid=$!
  trap 'kill "$pf_pid" >/dev/null 2>&1 || true' EXIT
  sleep 1
  curl -fsS http://127.0.0.1:19091/metrics >"$metrics_file" 2>/dev/null || true
fi

guard_args=(
  --bundle-file "$bundle_file"
  --out-json "$status_file"
  --out-metrics "$status_metrics_file"
)

if [[ -n "${SPIRE_AUTHORITY_STATE_FILE:-}" ]]; then
  cp "$SPIRE_AUTHORITY_STATE_FILE" "$OUT_DIR/spire_authority_state.json"
  guard_args+=(--spire-authority-state-file "$OUT_DIR/spire_authority_state.json")
fi

if [[ -n "${SPIRE_KEYS_FILE:-}" ]]; then
  cp "$SPIRE_KEYS_FILE" "$OUT_DIR/spire_keys.json"
  guard_args+=(--spire-keys-file "$OUT_DIR/spire_keys.json")
fi

python3 "$REPO_ROOT/scripts/trust/trust_root_lifecycle_guard.py" "${guard_args[@]}"

jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg bundle_file "$bundle_file" \
  --arg config_file "$config_file" \
  --arg logs_file "$logs_file" \
  --arg metrics_file "$metrics_file" \
  --arg status_file "$status_file" \
  '{
    generated_at: $generated_at,
    mutation_performed: false,
    evidence_files: {
      authoritative_bundle_pem: $bundle_file,
      spire_server_config: $config_file,
      spire_lifecycle_logs: $logs_file,
      spire_metrics: $metrics_file,
      root_lifecycle_status: $status_file
    }
  }' >"$OUT_DIR/spire_lifecycle_evidence_manifest.json"

echo "$OUT_DIR/spire_lifecycle_evidence_manifest.json"
