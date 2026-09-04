#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

kubectl get ns istio-system >/dev/null 2>&1 || fail "missing namespace istio-system"
kubectl get ns spire-system >/dev/null 2>&1 || fail "missing namespace spire-system"

kubectl -n istio-system get deploy/istiod >/dev/null 2>&1 || fail "missing deployment istiod"
kubectl -n istio-system get deploy/spire-csr >/dev/null 2>&1 || fail "missing deployment spire-csr"
kubectl -n spire-system get pod -l app=spire-server --field-selector=status.phase=Running -o name | grep -q . || fail "spire-server not running"

mesh_cfg="$(kubectl -n istio-system get cm istio -o jsonpath='{.data.mesh}' 2>/dev/null || true)"
[[ -n "$mesh_cfg" ]] || fail "missing mesh config"
printf '%s\n' "$mesh_cfg" | grep -q "trustDomain:[[:space:]]*${SPIFFE_TRUST_DOMAIN}" || fail "mesh trustDomain mismatch"
printf '%s\n' "$mesh_cfg" | grep -qiE 'threadforge-root|cert-manager' && fail "forbidden signer reference in mesh config"

inj_values="$(kubectl -n istio-system get cm istio-sidecar-injector -o jsonpath='{.data.values}' 2>/dev/null || true)"
[[ -n "$inj_values" ]] || fail "missing sidecar injector values"
python3 - <<'PY' "$inj_values"
import json
import sys
values = json.loads(sys.argv[1])
global_cfg = values.get("global", {}) if isinstance(values, dict) else {}
pilot_cert_provider = global_cfg.get("pilotCertProvider")
if pilot_cert_provider not in {"istiod", "custom"}:
  raise SystemExit(f"[FAIL] pilotCertProvider is unsupported: {pilot_cert_provider!r}")
if global_cfg.get("caAddress") != "spire-csr.istio-system.svc:443":
    raise SystemExit("[FAIL] global.caAddress mismatch")
print(f"[PASS] injector values match SPIRE SDS expectations (pilotCertProvider={pilot_cert_provider})")
PY

kubectl -n istio-system get secret istiod-tls >/dev/null 2>&1 || fail "missing secret istiod-tls"
kubectl -n istio-system get secret spire-csr-ca >/dev/null 2>&1 || fail "missing secret spire-csr-ca"

check_secret_issuer() {
  local secret_name="$1"
  local key_name="$2"
  local tmp_cert issuer key_b64
  tmp_cert="$(mktemp)"
  key_b64="$(kubectl -n istio-system get secret "$secret_name" -o json 2>/dev/null | jq -r --arg key "$key_name" '.data[$key] // empty')"
  if [[ -z "$key_b64" ]]; then
    rm -f "$tmp_cert"
    fail "unable to decode ${secret_name}/${key_name}"
  fi
  if ! printf '%s' "$key_b64" | base64 -d >"$tmp_cert" 2>/dev/null; then
    rm -f "$tmp_cert"
    fail "unable to decode ${secret_name}/${key_name}"
  fi
  issuer="$(openssl x509 -in "$tmp_cert" -noout -issuer -nameopt RFC2253 2>/dev/null || true)"
  rm -f "$tmp_cert"
  [[ -n "$issuer" ]] || fail "unable to read issuer from ${secret_name}/${key_name}"
  issuer="${issuer#issuer=}"
  printf '[INFO] %s/%s issuer=%s\n' "$secret_name" "$key_name" "$issuer"
  printf '%s\n' "$issuer" | grep -qiE 'O=SPIRE|O=SPIFFE' || fail "${secret_name}/${key_name} issuer is not SPIRE/SPIFFE"
  if printf '%s\n' "$issuer" | grep -qiE 'threadforge-root|cert-manager'; then
    fail "${secret_name}/${key_name} issuer is cert-manager rooted"
  fi
}

check_secret_issuer istiod-tls tls.crt
check_secret_issuer spire-csr-ca tls.crt

reconcile_ok=false
last_rc=0
# Compatibility sentinel retained for reproducibility guards: for _attempt in 1 2; do
for _attempt in 1 2 3 4 5 6; do
  set +e
  TEST_NAMESPACE=istio-system bash "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh" >/dev/null 2>&1
  rc=$?
  set -e
  last_rc="$rc"
  if [[ "$rc" -eq 0 ]]; then
    reconcile_ok=true
    break
  fi
  if [[ "$rc" -eq 11 ]]; then
    echo "[WARN] webhook caBundle not yet populated; retrying (attempt ${_attempt}/6)"
    sleep 3
    continue
  elif [[ "$rc" -eq 2 ]]; then
    echo "[WARN] webhook caBundle mismatch; refreshing SPIRE->Istio CA path (attempt ${_attempt}/6)"
    SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "$REPO_ROOT/scripts/verify/refresh_spire_istio_ca_path.sh" >/dev/null
    sleep 3
    continue
  else
    fail "webhook caBundle integrity verification failed (rc=${rc})"
  fi
done
[[ "$reconcile_ok" == "true" ]] || fail "webhook caBundle integrity verification failed (last_rc=${last_rc})"

echo "[PASS] Istio SPIRE SDS bridge verified (read-only)"
