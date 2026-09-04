#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=LIVENESS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

TIMEOUT_SECONDS="${SVID_STABILITY_TIMEOUT_SECONDS:-120}"
INTERVAL_SECONDS="${SVID_STABILITY_INTERVAL_SECONDS:-5}"
TEST_NAMESPACE="${SVID_STABILITY_NAMESPACE:-threadforge-test}"
TEST_LABEL="${SVID_STABILITY_TEST_LABEL:-app=test-client}"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/svid_stability_failure.log"
deadline="$(( $(date +%s) + TIMEOUT_SECONDS ))"
EXPECTED_SPIFFE_URI="${SVID_STABILITY_SPIFFE_URI:-spiffe://identity.threadforge.local/ns/${TEST_NAMESPACE}/sa/test-client}"
LAST_FAILURE_REASON=""
LAST_SAMPLE_POD=""
LAST_SAMPLE_CONTAINER="istio-proxy"
LAST_SAMPLE_COMMAND=""
LAST_RAW_CERT_DUMP=""
LAST_PARSE_RESULT=""
LAST_CERT_SUMMARY=""

fail() {
  echo "[FAIL] SVID NOT STABLE — $1"
  exit 2
}

write_debug_log() {
  mkdir -p "$(dirname "$DEBUG_LOG_PATH")"
  {
    echo "failure_reason=$LAST_FAILURE_REASON"
    echo "sampled_pod=$LAST_SAMPLE_POD"
    echo "sampled_container=$LAST_SAMPLE_CONTAINER"
    echo "cert_read_command=$LAST_SAMPLE_COMMAND"
    echo "parse_result=$LAST_PARSE_RESULT"
    echo "current_cert_summary=$LAST_CERT_SUMMARY"
    echo "raw_cert_dump<<'EOF'"
    printf '%s\n' "$LAST_RAW_CERT_DUMP"
    echo "EOF"
  } > "$DEBUG_LOG_PATH"
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    write_debug_log
  fi
}
trap on_exit EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

require_cmd kubectl
require_cmd python3

REAL_KUBECTL="$(resolve_real_kubectl)"

test_pod() {
  timeout --foreground 5s "$REAL_KUBECTL" get pod -n "$TEST_NAMESPACE" -l "$TEST_LABEL" --request-timeout=5s -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1
}

sample_for_pod() {
  local pod="$1"
  LAST_SAMPLE_POD="$pod"
  LAST_SAMPLE_COMMAND="$(resolve_real_kubectl) -n ${TEST_NAMESPACE} exec ${pod} -c ${LAST_SAMPLE_CONTAINER} -- curl -s http://127.0.0.1:15000/certs"
  LAST_RAW_CERT_DUMP="$(timeout --foreground 10s "$REAL_KUBECTL" exec -n "$TEST_NAMESPACE" "$pod" -c "$LAST_SAMPLE_CONTAINER" -- curl -s --max-time 5 http://127.0.0.1:15000/certs 2>/dev/null || true)"
  [ -n "$LAST_RAW_CERT_DUMP" ] || return 1
  python3 - "$LAST_RAW_CERT_DUMP" "$EXPECTED_SPIFFE_URI" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
expected_uri = sys.argv[2]
certs = doc.get("certificates") if isinstance(doc, dict) else None
if not isinstance(certs, list):
    raise SystemExit(1)

summaries = []
for cert in certs:
    if not isinstance(cert, dict):
        continue
    for entry in cert.get("cert_chain") or []:
        if not isinstance(entry, dict):
            continue
        san_uris = [
            san.get("uri")
            for san in (entry.get("subject_alt_names") or [])
            if isinstance(san, dict) and isinstance(san.get("uri"), str)
        ]
        serial = entry.get("serial_number")
        valid_from = entry.get("valid_from")
        expiration_time = entry.get("expiration_time")
        if isinstance(serial, str) and serial:
            summaries.append(f"{serial}|{valid_from or ''}|{expiration_time or ''}|{','.join(san_uris)}")
        if expected_uri in san_uris and isinstance(serial, str) and isinstance(valid_from, str) and isinstance(expiration_time, str):
            print(f"{serial}\t{valid_from}\t{expiration_time}\t{' ; '.join(summaries)}")
            raise SystemExit(0)

raise SystemExit(1)
PY
}

echo "[svid] waiting for stable SVID state"
last_error=""
previous_serial=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  pod="$(test_pod)"
  if [ -z "$pod" ]; then
    last_error="no running test-client pod"
  else
    sample="$(sample_for_pod "$pod" 2>/dev/null || true)"
    if [ -z "$sample" ]; then
      LAST_PARSE_RESULT="no matching Envoy leaf found for ${EXPECTED_SPIFFE_URI}"
      last_error="unable to parse Envoy leaf certificate for ${EXPECTED_SPIFFE_URI}"
    else
      serial="${sample%%$'\t'*}"
      remainder="${sample#*$'\t'}"
      valid_from="${remainder%%$'\t'*}"
      remainder="${remainder#*$'\t'}"
      not_after="${remainder%%$'\t'*}"
      cert_summary="${remainder#*$'\t'}"
      LAST_PARSE_RESULT="serial=${serial} valid_from=${valid_from} expiration_time=${not_after}"
      LAST_CERT_SUMMARY="$cert_summary"
      if [ -n "$previous_serial" ] && [ "$serial" = "$previous_serial" ]; then
        echo "[PASS] SVID serial stable via Envoy /certs"
        exit 0
      else
        previous_serial="$serial"
        last_error="awaiting consecutive identical Envoy leaf serial samples"
      fi
    fi
  fi

  sleep "$INTERVAL_SECONDS"
done

LAST_FAILURE_REASON="$last_error"
fail "${last_error:-VERIFY_TIMEOUT}"
