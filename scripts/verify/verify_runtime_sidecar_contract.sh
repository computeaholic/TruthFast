#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"
source "$REPO_ROOT/scripts/lib/envoy_admin.sh"
NAMESPACE="${1:-${RUNTIME_CONTRACT_NAMESPACE:-threadforge-test}}"
POD_NAME="${2:-${RUNTIME_CONTRACT_POD:-}}"
TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

if [[ -z "$POD_NAME" ]]; then
  fail "target pod name required as arg1 or RUNTIME_CONTRACT_POD"
fi

pod_json="$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o json 2>/dev/null)" || fail "unable to read pod ${NAMESPACE}/${POD_NAME}"
service_account="$(printf '%s' "$pod_json" | jq -r '.spec.serviceAccountName // "default"')"

printf '%s' "$pod_json" | jq -e '.spec.containers[] | select(.name == "istio-proxy")' >/dev/null || fail "pod admitted without istio-proxy sidecar (${NAMESPACE}/${POD_NAME})"

certs_json_file="$(mktemp)"
secret_json_file="$(mktemp)"
leaf_pem="$(mktemp)"
trap 'rm -f "$certs_json_file" "$secret_json_file" "$leaf_pem"' EXIT

capture_envoy_certs "$NAMESPACE" "$POD_NAME" "$certs_json_file" \
  || fail "Envoy certificate observation UNOBSERVABLE for ${NAMESPACE}/${POD_NAME}"
certs_output="$(cat "$certs_json_file")"

expected_spiffe="spiffe://${TRUST_DOMAIN}/ns/${NAMESPACE}/sa/${service_account}"
printf '%s' "$certs_output" | grep -F "$expected_spiffe" >/dev/null || fail "expected SPIFFE identity missing: ${expected_spiffe}"

capture_envoy_secrets "$NAMESPACE" "$POD_NAME" "$secret_json_file" \
  || fail "Envoy SDS observation UNOBSERVABLE for ${NAMESPACE}/${POD_NAME}"

if ! python3 - "$secret_json_file" "$leaf_pem" <<'PY'
import base64
import json
import re
import sys

secret_path = sys.argv[1]
leaf_path = sys.argv[2]
doc = json.load(open(secret_path, encoding="utf-8"))
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
with open(leaf_path, "w", encoding="utf-8") as handle:
    handle.write(parts[0] + "\n")
PY
then
  fail "malformed default SDS identity secret for ${NAMESPACE}/${POD_NAME}"
fi

issuer="$(openssl x509 -in "$leaf_pem" -noout -issuer -nameopt RFC2253 2>/dev/null || true)"
[[ -n "$issuer" ]] || fail "unable to parse leaf certificate issuer for ${NAMESPACE}/${POD_NAME}"
printf '%s' "$issuer" | grep -qi 'SPIRE' || fail "leaf certificate issuer is not SPIRE: $issuer"

echo "[PASS] runtime sidecar contract satisfied"
echo "namespace=$NAMESPACE"
echo "pod=$POD_NAME"
echo "service_account=$service_account"
echo "spiffe_id=$expected_spiffe"
echo "issuer=${issuer#issuer=}"
