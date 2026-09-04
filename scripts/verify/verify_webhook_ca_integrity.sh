#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$({ cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd; })"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

SPIRE_NS="${SPIRE_NS:-spire-system}"
SPIRE_POD="${SPIRE_POD:-spire-server-0}"
ROOT_CERT_NAMESPACE="${ROOT_CERT_NAMESPACE:-spire-system}"
ROOT_CERT_CONFIGMAP="${ROOT_CERT_CONFIGMAP:-spire-ca-root-cert}"
TEST_NAMESPACE="${TEST_NAMESPACE:-threadforge-test}"
TEST_IMAGE="${TEST_IMAGE:-registry.threadforge.local:30500/mirror/docker.io/library/busybox@sha256:bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

WEBHOOK_CA_DRYRUN_RETRIES="${WEBHOOK_CA_DRYRUN_RETRIES:-5}"
WEBHOOK_CA_DRYRUN_INTERVAL_SECONDS="${WEBHOOK_CA_DRYRUN_INTERVAL_SECONDS:-3}"

fail_contract() {
  echo "[FAIL] $1"
  exit "${2:-2}"
}

not_ready() {
  echo "[FAIL] WEBHOOK_CA_NOT_READY: $1"
  exit 11
}

validate_cert_file() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    fail_contract "WEBHOOK_CA_EMPTY" 2
  fi
  if [[ "$(wc -c < "$file" | tr -d ' ')" -lt 64 ]]; then
    fail_contract "WEBHOOK_CA_EMPTY" 2
  fi
  if ! openssl x509 -in "$file" -noout >/dev/null 2>&1; then
    fail_contract "WEBHOOK_CA_INVALID_FORMAT" 2
  fi
}

fingerprint_file() {
  local in_file="$1"
  local out_file="$2"
  openssl x509 -in "$in_file" -noout -fingerprint -sha256 >"$out_file" 2>/dev/null \
    || fail_contract "WEBHOOK_CA_INVALID_FORMAT" 2
}

extract_spire_root_to_file() {
  local out_file="$1"
  kubectl -n "$ROOT_CERT_NAMESPACE" get configmap "$ROOT_CERT_CONFIGMAP" \
    -o jsonpath='{.data.root-cert\.pem}' >"$out_file" 2>/dev/null || true
  [[ -s "$out_file" ]] || not_ready "unable to extract SPIRE root certificate"
  validate_cert_file "$out_file"
}

extract_single_webhook_cabundle_to_file() {
  local kind="$1"
  local name="$2"
  local json_file="$3"
  local bundle_lines="$4"
  local unique_bundle="$5"
  local pem_file="$6"
  kubectl get "$kind" "$name" -o json >"$json_file" 2>/dev/null || not_ready "$kind/$name not found"
  jq -r '.webhooks[]?.clientConfig.caBundle // empty' "$json_file" | sed '/^$/d' >"$bundle_lines"
  if [[ ! -s "$bundle_lines" ]]; then
    not_ready "$kind/$name caBundle not populated"
  fi
  sort -u "$bundle_lines" >"$unique_bundle"
  if [[ "$(wc -l < "$unique_bundle" | tr -d ' ')" != "1" ]]; then
    fail_contract "WEBHOOK_CA_MISMATCH" 2
  fi
  if ! base64 -d "$unique_bundle" >"$pem_file" 2>/dev/null; then
    fail_contract "WEBHOOK_CA_INVALID_FORMAT" 2
  fi
  validate_cert_file "$pem_file"
}

dryrun_probe_is_retryable() {
  local output_file="$1"
  grep -qiE 'context deadline exceeded|timed out|timeout|no endpoints available for service|service unavailable|connection refused|tls handshake timeout|failed calling webhook|webhook.*failed|currently unable to handle the request|i/o timeout|Client\.Timeout exceeded while awaiting headers|EOF' "$output_file"
}

run_dryrun_probe() {
  local manifest_file="$1"
  local output_file="$2"
  local rc=0

  if kubectl apply --dry-run=server -f "$manifest_file" >"$output_file" 2>&1; then
    echo "[PASS] webhook_ca_integrity=PASS"
    return 0
  fi
  rc=$?

  if grep -qi 'x509: certificate signed by unknown authority' "$output_file"; then
    fail_contract "WEBHOOK_CA_MISMATCH" 2
  fi
  if grep -qiE 'admission webhook|denied the request|forbidden|policy' "$output_file"; then
    echo "[PASS] webhook_ca_integrity=PASS (admission denial confirms webhook TLS reachability)"
    return 0
  fi
  if dryrun_probe_is_retryable "$output_file"; then
    return 11
  fi

  return "$rc"
}

wait_for_dryrun_probe() {
  local manifest_file="$1"
  local output_file="$2"
  local attempt rc

  for ((attempt = 1; attempt <= WEBHOOK_CA_DRYRUN_RETRIES; attempt++)); do
    if run_dryrun_probe "$manifest_file" "$output_file"; then
      return 0
    fi
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      fail_contract "WEBHOOK_CA_MISMATCH" 2
    fi
    if [[ "$rc" -ne 11 ]]; then
      return "$rc"
    fi
    if [[ "$attempt" -lt "$WEBHOOK_CA_DRYRUN_RETRIES" ]]; then
      sleep "$WEBHOOK_CA_DRYRUN_INTERVAL_SECONDS"
    fi
  done

  not_ready "server-side dry-run probe did not respond"
}

verify_webhook_ca_matches_or_is_signed_by_spire_root() {
  local spire_root_file="$1"
  local webhook_ca_file="$2"
  local spire_fp_file="$3"
  local webhook_fp_file="$4"

  # Exact match is preferred.
  if cmp -s "$spire_fp_file" "$webhook_fp_file"; then
    return 0
  fi

  # Allow webhook certificate signed by SPIRE root.
  if openssl verify -CAfile "$spire_root_file" "$webhook_ca_file" >/dev/null 2>&1; then
    return 0
  fi

  fail_contract "WEBHOOK_CA_MISMATCH" 2
}

spire_root_pem="$TMP_DIR/spire-root.pem"
spire_fp="$TMP_DIR/spire.fp"
webhook_fp="$TMP_DIR/webhook.fp"
webhook_json="$TMP_DIR/webhook.json"
bundle_lines="$TMP_DIR/bundles.txt"
unique_bundle="$TMP_DIR/unique-bundle.txt"
webhook_pem="$TMP_DIR/webhook.pem"
probe_manifest="$TMP_DIR/probe.yaml"

extract_spire_root_to_file "$spire_root_pem"
fingerprint_file "$spire_root_pem" "$spire_fp"

mutating_seen=0
while IFS= read -r mwh; do
  [[ -n "$mwh" ]] || continue
  mutating_seen=1
  : >"$bundle_lines"
  : >"$unique_bundle"
  : >"$webhook_pem"
  extract_single_webhook_cabundle_to_file mutatingwebhookconfiguration "$mwh" "$webhook_json" "$bundle_lines" "$unique_bundle" "$webhook_pem"
  fingerprint_file "$webhook_pem" "$webhook_fp"
  verify_webhook_ca_matches_or_is_signed_by_spire_root "$spire_root_pem" "$webhook_pem" "$spire_fp" "$webhook_fp"
done < <(kubectl get mutatingwebhookconfiguration -o name 2>/dev/null | grep -i istio | sed 's|.*/||' || true)
[[ "$mutating_seen" == "1" ]] || not_ready "unable to locate any Istio mutating webhook configurations"

validating_seen=0
while IFS= read -r vwh; do
  [[ -n "$vwh" ]] || continue
  validating_seen=1
  : >"$bundle_lines"
  : >"$unique_bundle"
  : >"$webhook_pem"
  extract_single_webhook_cabundle_to_file validatingwebhookconfiguration "$vwh" "$webhook_json" "$bundle_lines" "$unique_bundle" "$webhook_pem"
  fingerprint_file "$webhook_pem" "$webhook_fp"
  verify_webhook_ca_matches_or_is_signed_by_spire_root "$spire_root_pem" "$webhook_pem" "$spire_fp" "$webhook_fp"
done < <(kubectl get validatingwebhookconfiguration -o name 2>/dev/null | grep -i istio | sed 's|^validatingwebhookconfiguration.admissionregistration.k8s.io/||' || true)
[[ "$validating_seen" == "1" ]] || not_ready "unable to locate any Istio validating webhook configurations"

kubectl get namespace "$TEST_NAMESPACE" >/dev/null 2>&1 || not_ready "missing prerequisite namespace: $TEST_NAMESPACE"
cat >"$probe_manifest" <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: webhook-ca-bundle-test
  namespace: ${TEST_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: app
    image: ${TEST_IMAGE}
    command: ["sh", "-c", "sleep 5"]
    resources:
      requests:
        cpu: "25m"
        memory: "32Mi"
      limits:
        cpu: "100m"
        memory: "128Mi"
MANIFEST

wait_for_dryrun_probe "$probe_manifest" "$TMP_DIR/dryrun.out"
