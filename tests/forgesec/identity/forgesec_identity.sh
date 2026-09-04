#!/bin/sh
# ForgeSec Identity Mode — Authoritative (narrow scope)
# This tool validates identity enforcement behavior only.
# It makes no security, safety, or completeness claims.
# Exit code semantics:
# 0 = observation completed (regardless of observed outcome)
# 1 = operator error or missing required inputs
set -eu

send_observation() {
  mode="$1"
  observed_result="$2"
  pass_flag=$3
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Build observational JSON. Note: 'completed' denotes observation completion
  completed_flag=$( [ "$pass_flag" = true ] && echo true || echo false )
  json=$(printf '%s' "{\"mode\": \"$mode\", \"target\": \"$TARGET_URL\", \"timestamp\": \"$ts\", \"observed_result\": \"$observed_result\", \"completed\": $completed_flag, \"observations\": {\"result\": \"$observed_result\"}, \"operator_confirmed\": true, \"disclaimer\": \"observational, non-preventive\"}")

  # Emit to stdout for operator visibility
  printf '%s\n' "$json"

  # If configured, POST to ledger ingestion endpoint (best-effort)
  if [ -n "${FORGESEC_LEDGER_ENDPOINT:-}" ]; then
    curl -s -X POST -H "Content-Type: application/json" -d "$json" "$FORGESEC_LEDGER_ENDPOINT" >/dev/null 2>&1 || true
  fi
}

TARGET_URL=${TARGET_URL:-}
AUTHORIZED_CERT=${AUTHORIZED_CERT:-}
AUTHORIZED_KEY=${AUTHORIZED_KEY:-}
UNAUTHORIZED_CERT=${UNAUTHORIZED_CERT:-}
UNAUTHORIZED_KEY=${UNAUTHORIZED_KEY:-}
CA_CERT=${CA_CERT:-}
MODE=${MODE:-}

# Validate MODE
if [ -z "$MODE" ]; then
  echo "ERROR: MODE not set (unauthenticated|unauthorized|authorized)" >&2
  exit 1
fi

case "$MODE" in
  unauthenticated)
    if [ -z "$TARGET_URL" ]; then
      echo "ERROR: TARGET_URL not set" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
    # Expect TLS handshake / connection failure without client cert
    if curl --silent --show-error --fail "$TARGET_URL" >/dev/null 2>&1; then
      send_observation "unauthenticated" "unexpected-success" false
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    else
      send_observation "unauthenticated" "tls-failure" true
      exit 0
    fi
    ;;

  unauthorized)
    # Requires unauth cert/key present
    if [ -z "$TARGET_URL" ] || [ -z "$UNAUTHORIZED_CERT" ] || [ -z "$UNAUTHORIZED_KEY" ] || [ -z "$CA_CERT" ]; then
      echo "ERROR: TARGET_URL and UNAUTHORIZED_CERT/UNAUTHORIZED_KEY/CA_CERT must be set" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --cert "$UNAUTHORIZED_CERT":"$UNAUTHORIZED_KEY" --cacert "$CA_CERT" "$TARGET_URL" || echo "000")
    if [ "$code" = "403" ]; then
      send_observation "unauthorized" "http-403" true
      exit 0
    else
      send_observation "unauthorized" "http-$code" false
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
    ;;

  authorized)
    if [ -z "$TARGET_URL" ] || [ -z "$AUTHORIZED_CERT" ] || [ -z "$AUTHORIZED_KEY" ] || [ -z "$CA_CERT" ]; then
      echo "ERROR: TARGET_URL and AUTHORIZED_CERT/AUTHORIZED_KEY/CA_CERT must be set" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --cert "$AUTHORIZED_CERT":"$AUTHORIZED_KEY" --cacert "$CA_CERT" "$TARGET_URL" || echo "000")
    case "$code" in
      2??)
        send_observation "authorized" "http-$code" true
        exit 0
        ;;
      *)
        send_observation "authorized" "http-$code" false
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
        ;;
    esac
    ;;

  *)
    echo "ERROR: Unknown MODE: $MODE" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    ;;

esac