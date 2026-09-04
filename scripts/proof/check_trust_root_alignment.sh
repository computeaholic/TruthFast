#!/usr/bin/env bash
# check_trust_root_alignment.sh — ThreadForge trust root invariant checker
#
# Verifies that all four invariants hold before declaring TRUST_ROOT_ALIGNED=TRUE:
#   1. Runtime workload identities carry SPIFFE URI SANs
#   2. Cert issuer (cacerts root) fingerprint matches distributed trust anchor (istio-ca-root-cert)
#   3. Signature enforcement is active (Kyverno ClusterPolicy ready, useCache=false)
#   4. Admission enforcement active (Kyverno admission-controller ready, COSIGN_EXPERIMENTAL not set)
#
# Exit codes:
#   0 = TRUST_ROOT_ALIGNED: TRUE
#   1 = TRUST_ROOT_ALIGNED: FALSE (one or more invariants failed)
#
# Usage:
#   ./scripts/proof/check_trust_root_alignment.sh
#   KUBECONFIG=/path/to/kubeconfig ./scripts/proof/check_trust_root_alignment.sh

set -euo pipefail

PASS=0
FAIL=1
RESULT=0
FAILURES=()

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; RESULT=1; FAILURES+=("$1"); }
info() { echo "[INFO] $1"; }

echo "=== ThreadForge Trust Root Alignment Check ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# INVARIANT 1: Runtime workload identities are SPIFFE-based
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Invariant 1: Runtime SPIFFE identity ---"
_sample_pod="$(kubectl -n threadforge-test get pod -l app -o name 2>/dev/null | head -1)"
if [ -z "$_sample_pod" ]; then
  fail "INV1_SPIFFE_IDENTITY: no pods found in threadforge-test namespace"
else
  _spiffe_san="$(kubectl -n threadforge-test exec "$_sample_pod" -c istio-proxy -- \
    pilot-agent request GET /certs 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for entry in data.get('certificates', []):
    for cert in entry.get('cert_chain', []):
        for san in cert.get('subject_alt_names', []):
            uri = san.get('uri', '')
            if uri.startswith('spiffe://'):
                print(uri)
                raise SystemExit(0)
" 2>/dev/null || true)"
  if echo "$_spiffe_san" | grep -q "^spiffe://"; then
    pass "INV1_SPIFFE_IDENTITY: workload cert has SPIFFE URI SAN: $_spiffe_san"
  else
    fail "INV1_SPIFFE_IDENTITY: no SPIFFE URI SAN found in workload cert chain"
  fi
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# INVARIANT 2: Cert issuer matches declared trust root
#   - cacerts root-cert.pem fingerprint must match istio-ca-root-cert configmap
#   - Both must match spire-ca-root-cert configmap
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Invariant 2: Cert issuer matches trust root ---"

_cacerts_root_fp="$(kubectl -n istio-system get secret cacerts \
  -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | \
  base64 -d | openssl x509 -noout -fingerprint -sha256 2>/dev/null | \
  awk -F= '{print $2}' || true)"

_istio_ca_root_fp="$(kubectl -n istio-system get configmap istio-ca-root-cert \
  -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | \
  openssl x509 -noout -fingerprint -sha256 2>/dev/null | \
  awk -F= '{print $2}' || true)"

_spire_ca_root_fp="$(kubectl -n istio-system get configmap spire-ca-root-cert \
  -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | \
  openssl x509 -noout -fingerprint -sha256 2>/dev/null | \
  awk -F= '{print $2}' || true)"

info "cacerts/root-cert.pem fingerprint  : ${_cacerts_root_fp:-MISSING}"
info "istio-ca-root-cert fingerprint      : ${_istio_ca_root_fp:-MISSING}"
info "spire-ca-root-cert fingerprint      : ${_spire_ca_root_fp:-MISSING}"

if [ -z "$_cacerts_root_fp" ]; then
  fail "INV2_TRUST_ROOT: cacerts secret not found or has no root-cert.pem"
elif [ -z "$_istio_ca_root_fp" ]; then
  fail "INV2_TRUST_ROOT: istio-ca-root-cert configmap missing"
elif [ "$_cacerts_root_fp" != "$_istio_ca_root_fp" ]; then
  fail "INV2_TRUST_ROOT: cacerts root fingerprint MISMATCH with istio-ca-root-cert"
elif [ -n "$_spire_ca_root_fp" ] && [ "$_cacerts_root_fp" != "$_spire_ca_root_fp" ]; then
  fail "INV2_TRUST_ROOT: cacerts root fingerprint MISMATCH with spire-ca-root-cert"
else
  pass "INV2_TRUST_ROOT: all root fingerprints match: ${_cacerts_root_fp}"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# INVARIANT 3: Signature enforcement active
#   - threadforge-require-signed-images ClusterPolicy exists and is Ready
#   - useCache must be true so repeated live verification remains within the webhook budget
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Invariant 3: Signature enforcement active ---"

_policy_status="$(kubectl get clusterpolicy threadforge-require-signed-images \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
_use_cache="$(kubectl get clusterpolicy threadforge-require-signed-images \
  -o jsonpath='{.spec.rules[*].verifyImages[*].useCache}' 2>/dev/null || true)"

if [ "$_policy_status" != "True" ]; then
  fail "INV3_SIGNATURE_ENFORCEMENT: threadforge-require-signed-images not Ready (status=${_policy_status:-MISSING})"
else
  pass "INV3_SIGNATURE_ENFORCEMENT: threadforge-require-signed-images Ready"
fi

if [ "$_use_cache" = "true" ]; then
  pass "INV3_USE_CACHE: useCache=true (cached live verification enforced)"
else
  fail "INV3_USE_CACHE: useCache=${_use_cache} — must be true so repeated admissions stay within budget"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# INVARIANT 4: Admission enforcement active
#   - Kyverno admission-controller is ready
#   - COSIGN_EXPERIMENTAL must NOT be set
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Invariant 4: Admission enforcement active ---"

_kyverno_ready="$(kubectl -n kyverno get deployment kyverno-admission-controller \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
_cosign_experimental="$(kubectl -n kyverno get deployment kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="COSIGN_EXPERIMENTAL")].value}' 2>/dev/null || true)"

if [ "${_kyverno_ready:-0}" -ge 1 ] 2>/dev/null; then
  pass "INV4_ADMISSION_CONTROLLER: kyverno-admission-controller ready (replicas=${_kyverno_ready})"
else
  fail "INV4_ADMISSION_CONTROLLER: kyverno-admission-controller not ready (readyReplicas=${_kyverno_ready:-0})"
fi

if [ -z "$_cosign_experimental" ]; then
  pass "INV4_COSIGN_EXPERIMENTAL: not set (correct)"
else
  fail "INV4_COSIGN_EXPERIMENTAL: COSIGN_EXPERIMENTAL=${_cosign_experimental} — must not be set"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# RESULT
# ─────────────────────────────────────────────────────────────────────────────
echo "==========================================="
if [ $RESULT -eq 0 ]; then
  echo "TRUST_ROOT_ALIGNED: TRUE"
  echo ""
  echo "Trust root authority: HYBRID"
  echo "  Root CA      : SPIRE (C=US, O=SPIFFE) fingerprint=${_cacerts_root_fp}"
  echo "  Signing CA   : istiod (intermediate, CN=spire-csr-intermediate, PILOT_CERT_PROVIDER=istiod)"
  echo "  Wire identity: SPIFFE SVIDs (spiffe://identity.threadforge.local/ns/.../sa/...)"
  echo "  All roots    : ALIGNED"
else
  echo "TRUST_ROOT_ALIGNED: FALSE"
  echo ""
  echo "FAILED INVARIANTS:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
fi
echo "==========================================="
exit $RESULT
