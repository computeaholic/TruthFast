#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_bin kubectl
require_bin openssl
require_bin jq
require_bin python3
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"
source "$REPO_ROOT/scripts/lib/envoy_admin.sh"
TRUST_AUTHORITY_STATE_FILE="${TRUST_AUTHORITY_STATE_FILE:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/trust/update_trust_authority_state.sh" >/dev/null
[[ -s "$TRUST_AUTHORITY_STATE_FILE" ]] || fail "unable to read trust authority state"
spire_root_pem="$(jq -r '.active_root_pem // empty' "$TRUST_AUTHORITY_STATE_FILE" 2>/dev/null || true)"
[[ -n "$spire_root_pem" ]] || fail "unable to read SPIRE active root"

spire_root_fp="$(printf '%s\n' "$spire_root_pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr '[:upper:]' '[:lower:]' | tr -d ':')"
[[ -n "$spire_root_fp" ]] || fail "unable to fingerprint SPIRE bundle root"

echo "SPIRE bundle root fingerprint: $spire_root_fp"

fail_count=0

check_issuer() {
  local cert_pem="$1"
  local source="$2"
  local issuer
  issuer="$(printf '%s\n' "$cert_pem" | openssl x509 -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')"
  if [[ -z "$issuer" ]]; then
    echo "[FAIL] ${source}: unable to parse issuer"
    fail_count=$((fail_count + 1))
    return
  fi
  echo "${source} issuer: ${issuer}"
  if ! printf '%s\n' "$issuer" | grep -qiE 'O=SPIRE|O=SPIFFE'; then
    echo "[FAIL] ${source}: issuer is not SPIRE/SPIFFE"
    fail_count=$((fail_count + 1))
  fi
  if printf '%s\n' "$issuer" | grep -qiE 'threadforge-root|cert-manager'; then
    echo "[FAIL] ${source}: issuer is cert-manager rooted"
    fail_count=$((fail_count + 1))
  fi
}

check_root_fp() {
  local cert_pem="$1"
  local source="$2"
  local fp
  fp="$(printf '%s\n' "$cert_pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr '[:upper:]' '[:lower:]' | tr -d ':')"
  if [[ -z "$fp" ]]; then
    echo "[FAIL] ${source}: unable to fingerprint root"
    fail_count=$((fail_count + 1))
    return
  fi
  echo "${source} root fingerprint: ${fp}"
  if [[ "$fp" != "$spire_root_fp" ]]; then
    echo "[FAIL] ${source}: root fingerprint does not match SPIRE bundle"
    fail_count=$((fail_count + 1))
  fi
}

echo ""
echo "== Istiod serving cert source =="
istiod_secret="$(kubectl get deploy -n istio-system istiod -o json | jq -r '.spec.template.spec.volumes[]? | select(.name=="istio-csr-dns-cert" and .secret.secretName != null) | .secret.secretName' | head -n1)"
[[ -n "$istiod_secret" ]] || fail "unable to determine istiod serving cert source"
echo "source secret: istio-system/${istiod_secret}"
istiod_tls_crt="$(kubectl get secret -n istio-system "$istiod_secret" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || true)"
[[ -n "$istiod_tls_crt" ]] || fail "unable to read istiod serving cert"
check_issuer "$istiod_tls_crt" "istiod"
kubectl get secret -n istio-system "$istiod_secret" -o jsonpath='{.data.ca\.crt}' >"$TMP_DIR/istiod_ca.b64" 2>/dev/null || true
if [[ -s "$TMP_DIR/istiod_ca.b64" ]]; then
  base64 -d <"$TMP_DIR/istiod_ca.b64" >"$TMP_DIR/istiod_ca.crt" 2>/dev/null || true
fi
istiod_ca_crt="$(cat "$TMP_DIR/istiod_ca.crt" 2>/dev/null || true)"
[[ -n "$istiod_ca_crt" ]] || fail "unable to read istiod serving root ca.crt"
check_root_fp "$istiod_ca_crt" "istiod"

echo ""
echo "== Webhook cert source =="
mutating_cabundle="$(kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o json | jq -r '.webhooks[0].clientConfig.caBundle')"
[[ -n "$mutating_cabundle" && "$mutating_cabundle" != "null" ]] || fail "unable to read mutating webhook caBundle"
webhook_root="$(printf '%s' "$mutating_cabundle" | base64 -d 2>/dev/null || true)"
[[ -n "$webhook_root" ]] || fail "unable to decode mutating webhook caBundle"
check_issuer "$webhook_root" "webhook"
check_root_fp "$webhook_root" "webhook"

echo ""
echo "== Ingress gateway cert source =="
gateway_pod="$(kubectl get pods -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$gateway_pod" ]] || fail "unable to locate ingressgateway pod"
gateway_secrets="$TMP_DIR/gateway-secrets.json"
capture_envoy_secrets istio-system "$gateway_pod" "$gateway_secrets" \
  || fail "gateway Envoy SDS observation UNOBSERVABLE"
rootca_b64="$(jq -r '.dynamicActiveSecrets[] | select(.name=="ROOTCA") | .secret.validationContext.trustedCa.inlineBytes' "$gateway_secrets" | head -n1)"
[[ -n "$rootca_b64" && "$rootca_b64" != "null" ]] || fail "unable to read gateway ROOTCA"
gateway_root="$(printf '%s' "$rootca_b64" | base64 -d 2>/dev/null || true)"
[[ -n "$gateway_root" ]] || fail "unable to decode gateway ROOTCA"
check_issuer "$gateway_root" "ingressgateway"
check_root_fp "$gateway_root" "ingressgateway"

echo ""
echo "== cert-manager issuers =="
kubectl get issuer,clusterissuer -A 2>/dev/null || true

echo ""
echo "== TLS secrets used by Istio deployments =="
secret_names="$(kubectl get deploy -n istio-system istiod istio-ingressgateway -o json | jq -r '.items[].spec.template.spec.volumes[]? | select(.secret.secretName != null) | .secret.secretName' | sort -u)"
if [[ -z "$secret_names" ]]; then
  echo "none"
else
  while IFS= read -r secret_name; do
    [[ -n "$secret_name" ]] || continue
    echo "secret: istio-system/${secret_name}"
    cert_data="$(kubectl get secret -n istio-system "$secret_name" -o json 2>/dev/null || true)"
    [[ -n "$cert_data" ]] || continue
    for key in tls.crt ca.crt cert-chain.pem root-cert.pem; do
      b64="$(printf '%s\n' "$cert_data" | jq -r --arg k "$key" '.data[$k] // empty')"
      [[ -n "$b64" ]] || continue
      pem="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
      [[ -n "$pem" ]] || continue
      check_issuer "$pem" "${secret_name}/${key}"
      if [[ "$key" == "ca.crt" || "$key" == "root-cert.pem" ]]; then
        check_root_fp "$pem" "${secret_name}/${key}"
      fi
    done
  done <<< "$secret_names"
fi

if (( fail_count > 0 )); then
  fail "detected ${fail_count} non-SPIRE control-plane certificate invariants"
fi

echo "[PASS] SPIRE is the sole control-plane CA source"
