#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"
TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"
TRUST_AUTHORITY_STATE_FILE="${TRUST_AUTHORITY_STATE_FILE:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
RUNTIME_IDENTITY_RETRIES="${RUNTIME_IDENTITY_RETRIES:-5}"
RUNTIME_IDENTITY_RETRY_INTERVAL_SECONDS="${RUNTIME_IDENTITY_RETRY_INTERVAL_SECONDS:-2}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
DEBUG_DIR="$REPO_ROOT/artifacts/debug"
mkdir -p "$DEBUG_DIR"
# shellcheck source=scripts/lib/envoy_admin.sh
source "$REPO_ROOT/scripts/lib/envoy_admin.sh"

fail() {
  echo "[FAIL] $1"
  exit 2
}

fail_identity_mismatch() {
  local pod="$1"
  local ns="$2"
  local resolved_sa="$3"
  local expected_spiffe="$4"
  local actual_spiffe="$5"
  echo "[FAIL] RUNTIME_IDENTITY_MISMATCH:"
  echo "pod=${pod}"
  echo "namespace=${ns}"
  echo "resolved_sa=${resolved_sa}"
  echo "expected_spiffe=${expected_spiffe}"
  echo "actual_spiffe=${actual_spiffe}"
  exit 2
}

retry_kubectl_exec_capture() {
  local out_file="$1"
  shift
  local attempt
  for attempt in $(seq 1 "$RUNTIME_IDENTITY_RETRIES"); do
    if kubectl exec "$@" >"$out_file" 2>/dev/null; then
      return 0
    fi
    if (( attempt < RUNTIME_IDENTITY_RETRIES )); then
      sleep "$RUNTIME_IDENTITY_RETRY_INTERVAL_SECONDS"
    fi
  done
  return 1
}

retry_kubectl_get_pod_json() {
  local ns="$1"
  local pod="$2"
  local out_file="$3"
  local attempt
  for attempt in $(seq 1 "$RUNTIME_IDENTITY_RETRIES"); do
    if kubectl get pod -n "$ns" "$pod" -o json >"$out_file" 2>/dev/null; then
      return 0
    fi
    if (( attempt < RUNTIME_IDENTITY_RETRIES )); then
      sleep "$RUNTIME_IDENTITY_RETRY_INTERVAL_SECONDS"
    fi
  done
  return 1
}

spire_root_pem="$TMP_DIR/spire-root.pem"
spire_fp_file="$TMP_DIR/spire.fp"

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
[[ -s "$TRUST_AUTHORITY_STATE_FILE" ]] || fail "RUNTIME_CA_DRIFT: trust authority state unavailable"
jq -r '.active_root_pem // empty' "$TRUST_AUTHORITY_STATE_FILE" >"$spire_root_pem" 2>/dev/null || true

[[ -s "$spire_root_pem" ]] || fail "RUNTIME_CA_DRIFT: unable to load SPIRE active root"
openssl x509 -in "$spire_root_pem" -noout >/dev/null 2>&1 || fail "RUNTIME_CA_DRIFT: SPIRE active root invalid"
openssl x509 -in "$spire_root_pem" -noout -fingerprint -sha256 >"$spire_fp_file"

pods_json="$TMP_DIR/pods.json"
kubectl get pods -A -o json >"$pods_json"

mapfile -t pods < <(jq -r '.items[]
  | select(.status.phase=="Running")
  | select((.status.conditions // []) | any(.type=="Ready" and .status=="True"))
  | select((.spec.containers // []) | map(.name) | index("istio-proxy"))
  | select((.status.containerStatuses // []) | any(.name=="istio-proxy" and .ready==true))
  | "\(.metadata.namespace) \(.metadata.name)"' "$pods_json")

[[ "${#pods[@]}" -gt 0 ]] || fail "RUNTIME_IDENTITY_MISMATCH: no injected workloads found"

required_namespaces=(
  threadforge-system
  observability
  istio-system
  minio
  threadforge-test
)
declare -A verified_namespaces=()

for row in "${pods[@]}"; do
  ns="${row%% *}"
  pod="${row##* }"

  pod_json="$TMP_DIR/${ns}_${pod}_pod.json"
  if ! retry_kubectl_get_pod_json "$ns" "$pod" "$pod_json"; then
    # Pod may have rolled during long proof runs; skip and verify another pod.
    continue
  fi

  # Deterministic SA resolution order:
  # 1) .spec.serviceAccountName
  # 2) .spec.serviceAccount
  # 3) default
  sa="$(jq -r '.spec.serviceAccountName // empty' "$pod_json" 2>/dev/null || true)"
  if [[ -z "$sa" ]]; then
    sa="$(jq -r '.spec.serviceAccount // empty' "$pod_json" 2>/dev/null || true)"
  fi
  if [[ -z "$sa" ]]; then
    sa="default"
  fi
  if [[ -z "$sa" ]]; then
    snippet_file="$DEBUG_DIR/runtime_identity_missing_sa_${ns}_${pod}.json"
    jq '{
      metadata: {
        name: .metadata.name,
        namespace: .metadata.namespace,
        labels: .metadata.labels
      },
      spec: {
        serviceAccountName: .spec.serviceAccountName,
        serviceAccount: .spec.serviceAccount,
        automountServiceAccountToken: .spec.automountServiceAccountToken,
        containers: [(.spec.containers[]? | {name, image})]
      }
    }' "$pod_json" >"$snippet_file" 2>/dev/null || cp "$pod_json" "$snippet_file"
    fail "RUNTIME_IDENTITY_MISSING_SA: pod=${pod} namespace=${ns} debug_pod_snippet=${snippet_file}"
  fi

  expected_spiffe_id="spiffe://${TRUST_DOMAIN}/ns/${ns}/sa/${sa}"

  certs_file="$TMP_DIR/${ns}_${pod}_certs.json"
  if ! retry_kubectl_exec_capture "$certs_file" -n "$ns" -c istio-proxy "$pod" -- pilot-agent request GET /certs; then
    # Retry candidates within the namespace before failing globally.
    continue
  fi

  mapfile -t spiffe_ids < <(sed -n 's/.*"uri":[[:space:]]*"\(spiffe:\/\/[^"[:space:]]*\)".*/\1/p' "$certs_file")
  if [[ "${#spiffe_ids[@]}" -eq 0 ]]; then
    fail_identity_mismatch "$pod" "$ns" "$sa" "$expected_spiffe_id" "NONE"
  fi

  actual_spiffe_id="NONE"
  if printf '%s\n' "${spiffe_ids[@]}" | grep -Fxq "$expected_spiffe_id"; then
    actual_spiffe_id="$expected_spiffe_id"
  else
    actual_spiffe_id="${spiffe_ids[0]}"
  fi

  if ! printf '%s\n' "${spiffe_ids[@]}" | grep -Fxq "$expected_spiffe_id"; then
    fail_identity_mismatch "$pod" "$ns" "$sa" "$expected_spiffe_id" "$actual_spiffe_id"
  fi

  unexpected_ids="$(printf '%s\n' "${spiffe_ids[@]}" | grep -vFx "$expected_spiffe_id" | grep -vFx "spiffe://${TRUST_DOMAIN}" || true)"
  if [[ -n "$unexpected_ids" ]]; then
    fail_identity_mismatch "$pod" "$ns" "$sa" "$expected_spiffe_id" "$unexpected_ids"
  fi

  # Validate live SDS-serving leaf issuer is SPIRE-derived.
  secret_json="$TMP_DIR/${ns}_${pod}_secret.json"
  if ! capture_envoy_secrets "$ns" "$pod" "$secret_json" 2>/dev/null; then
    continue
  fi

  leaf_pem="$TMP_DIR/${ns}_${pod}_leaf.pem"
  python3 - "$secret_json" "$leaf_pem" <<'PY'
import base64
import json
import re
import sys

secret_json, leaf_path = sys.argv[1], sys.argv[2]
doc = json.load(open(secret_json))
dynamic = doc.get("dynamicActiveSecrets") or []
default_entries = [x for x in dynamic if isinstance(x, dict) and x.get("name") == "default"]
if len(default_entries) != 1:
    raise SystemExit(2)
chain_b64 = ((((default_entries[0].get("secret") or {}).get("tlsCertificate") or {}).get("certificateChain") or {}).get("inlineBytes"))
if not chain_b64:
    raise SystemExit(2)
pem = base64.b64decode(chain_b64).decode("utf-8", "ignore")
parts = re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", pem)
if not parts:
    raise SystemExit(2)
with open(leaf_path, "w", encoding="utf-8") as f:
    f.write(parts[0] + "\n")
PY
  if [[ $? -ne 0 ]] || [[ ! -s "$leaf_pem" ]]; then
    fail "RUNTIME_IDENTITY_MISMATCH: invalid SDS certificate chain for ${ns}/${pod}"
  fi

  issuer_line="$(openssl x509 -in "$leaf_pem" -noout -issuer -nameopt RFC2253 2>/dev/null || true)"
  issuer_value="${issuer_line#issuer=}"
  [[ -n "$issuer_value" ]] || fail "RUNTIME_IDENTITY_MISMATCH: missing issuer on SDS leaf for ${ns}/${pod}"
  if ! printf '%s\n' "$issuer_value" | grep -qi 'SPIRE'; then
    fail "RUNTIME_IDENTITY_MISMATCH: SDS leaf issuer is not SPIRE for ${ns}/${pod} (${issuer_value})"
  fi

  root_file="$TMP_DIR/${ns}_${pod}_root.pem"
  if ! retry_kubectl_exec_capture "$root_file" -n "$ns" -c istio-proxy "$pod" -- sh -ec 'cat /etc/certs/root-cert.pem'; then
    # Some workloads do not project /etc/certs/root-cert.pem; in that case use
    # the live ROOTCA from Envoy SDS, which is the authoritative runtime source.
    python3 - "$secret_json" "$root_file" <<'PY'
import base64
import json
import re
import sys

secret_json, root_path = sys.argv[1], sys.argv[2]
doc = json.load(open(secret_json))
dynamic = doc.get("dynamicActiveSecrets") or []
root_entries = [x for x in dynamic if isinstance(x, dict) and x.get("name") == "ROOTCA"]
if len(root_entries) != 1:
    raise SystemExit(2)
root_b64 = ((((root_entries[0].get("secret") or {}).get("validationContext") or {}).get("trustedCa") or {}).get("inlineBytes"))
if not root_b64:
    raise SystemExit(2)
pem = base64.b64decode(root_b64).decode("utf-8", "ignore")
parts = re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", pem)
if len(parts) != 1:
    raise SystemExit(2)
with open(root_path, "w", encoding="utf-8") as f:
    f.write(parts[0] + "\n")
PY
    if [[ $? -ne 0 ]]; then
      fail "RUNTIME_CA_DRIFT: missing runtime root cert for ${ns}/${pod}"
    fi
  fi
  [[ -s "$root_file" ]] || fail "RUNTIME_CA_DRIFT: empty runtime root cert for ${ns}/${pod}"
  openssl x509 -in "$root_file" -noout >/dev/null 2>&1 || fail "RUNTIME_CA_DRIFT: invalid runtime root cert for ${ns}/${pod}"

  # Accept active root or active-root-signed issuance intermediates only.
  if ! openssl verify -CAfile "$spire_root_pem" "$root_file" >/dev/null 2>&1; then
    fail "RUNTIME_CA_DRIFT: runtime root does not chain to active SPIRE root for ${ns}/${pod}"
  fi

  root_fp_file="$TMP_DIR/${ns}_${pod}.fp"
  openssl x509 -in "$root_file" -noout -fingerprint -sha256 >"$root_fp_file"

  verified_namespaces["$ns"]=1

done

for required_ns in "${required_namespaces[@]}"; do
  if [[ -z "${verified_namespaces[$required_ns]:-}" ]]; then
    fail "RUNTIME_IDENTITY_MISMATCH: required namespace had no verified sidecar pods: ${required_ns}"
  fi
done

echo "[PASS] runtime_identity_truth=PASS"
