#!/usr/bin/env bash
# Refresh SPIRE->Istio CA issuance path from the active SPIRE root and live SPIRE bundle.
# This script intentionally fails closed and does not use local/non-SPIRE fallback CAs.

set -euo pipefail

SPIRE_ROLLOUT_TIMEOUT="${SPIRE_ROLLOUT_TIMEOUT:-180}"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRUST_AUTHORITY_STATE_FILE="${TRUST_AUTHORITY_STATE_FILE:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
ACTIVE_ROOT_PEM_FILE=""
SPIRE_BUNDLE_PEM_FILE=""
PROOF_TRUST_ROOT_PEM_FILE="${PROOF_TRUST_ROOT_PEM_FILE:-}"

fail() {
  echo "[FAIL] SPIRE_CSR_STALE_ROOT: $1"
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_cmd kubectl
require_cmd openssl
require_cmd jq
require_cmd base64

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
# shellcheck source=scripts/lib/spire_server_socket.sh
source "$REPO_ROOT/scripts/lib/spire_server_socket.sh"

load_active_root_from_state() {
  if [[ "${VERIFY_EXECUTION_MODE:-}" == "proof" && -n "$PROOF_TRUST_ROOT_PEM_FILE" && -s "$PROOF_TRUST_ROOT_PEM_FILE" ]]; then
    cat "$PROOF_TRUST_ROOT_PEM_FILE"
    return 0
  fi
  bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
  jq -r '.active_root_pem // empty' "$TRUST_AUTHORITY_STATE_FILE" 2>/dev/null \
    || fail "unable to read active SPIRE root from trust authority state"
}

load_live_spire_bundle() {
  local spire_server_pod
  spire_server_pod="$(select_active_spire_server_pod spire-system || true)"
  [[ -n "$spire_server_pod" ]] || fail "live SPIRE server pod unavailable"
  kubectl exec -n spire-system -c spire-server "$spire_server_pod" -- /opt/spire/bin/spire-server bundle show \
    -socketPath "$SPIRE_SERVER_SOCKET_PATH" -format pem 2>/dev/null \
    || fail "unable to read live SPIRE bundle"
}

proof_mode_active() {
  declare -f kubectl 2>/dev/null | grep -q 'PROOF_MUTATION_BLOCKED'
}

openssl_sign_request() {
  local csr_path="$1"
  local ca_cert_path="$2"
  local ca_key_path="$3"
  local serial_path="$4"
  local out_path="$5"
  local days="$6"
  local extfile_path="$7"

  # OpenSSL aborts if -CAserial points at an empty file. Remove zero-byte
  # leftovers and let -CAcreateserial recreate the serial state safely.
  if [[ -e "$serial_path" && ! -s "$serial_path" ]]; then
    rm -f "$serial_path"
  fi

  openssl x509 -req -in "$csr_path" -CA "$ca_cert_path" -CAkey "$ca_key_path" \
    -CAserial "$serial_path" -CAcreateserial \
    -out "$out_path" -days "$days" -sha256 -extfile "$extfile_path"
}

json_secret_field() {
  local ns="$1" name="$2" field="$3"
  kubectl -n "$ns" get secret "$name" -o json 2>/dev/null | jq -r --arg field "$field" '.data[$field] // empty'
}

json_configmap_field() {
  local ns="$1" name="$2" field="$3"
  kubectl -n "$ns" get configmap "$name" -o json 2>/dev/null | jq -r --arg field "$field" '.data[$field] // empty'
}

bundle_hashes_from_pem_file() {
  local pem_file="$1"
  python3 - "$pem_file" <<'PY'
import hashlib
import pathlib
import re
import ssl
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
certs = [m.strip() + "\n" for m in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", text or "")]
hashes = sorted({hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem).replace(b"\r", b"")).hexdigest() for pem in certs})
for value in hashes:
    print(value)
PY
}

compare_bundle_hash_sets() {
  local expected_pem_file="$1"
  local actual_pem_file="$2"
  local context="$3"
  local expected_hashes actual_hashes

  expected_hashes="$(bundle_hashes_from_pem_file "$expected_pem_file")"
  actual_hashes="$(bundle_hashes_from_pem_file "$actual_pem_file")"

  if [[ "$expected_hashes" != "$actual_hashes" ]]; then
    echo "[DEBUG] expected_bundle_hashes=${expected_hashes//$'\n'/,}"
    echo "[DEBUG] actual_bundle_hashes=${actual_hashes//$'\n'/,}"
    fail "${context} caBundle does not match authoritative SPIRE bundle"
  fi
}

bundle_includes_active_root_and_is_spire_issued() {
  local expected_pem_file="$1"
  local actual_pem_file="$2"
  local context="$3"
  python3 - "$expected_pem_file" "$actual_pem_file" "$context" <<'PY'
import hashlib
import pathlib
import re
import ssl
import subprocess
import sys
import tempfile

expected_pem_path = pathlib.Path(sys.argv[1])
actual_pem_path = pathlib.Path(sys.argv[2])
context = sys.argv[3]

def certs(text: str):
    return [m.strip() + "\n" for m in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", text or "")]

expected_certs = certs(expected_pem_path.read_text(encoding="utf-8"))
actual_certs = certs(actual_pem_path.read_text(encoding="utf-8"))
if not expected_certs:
    print(f"[FAIL] CONTRACT_VIOLATION: {context} expected active root PEM is empty", file=sys.stderr)
    raise SystemExit(2)
if not actual_certs:
    print(f"[FAIL] CONTRACT_VIOLATION: {context} caBundle contains no certs", file=sys.stderr)
    raise SystemExit(2)

def pem_hash(pem: str) -> str:
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem).replace(b"\r", b"")).hexdigest()

expected_hash = pem_hash(expected_certs[0])
actual_hashes = {pem_hash(cert) for cert in actual_certs}
if expected_hash not in actual_hashes:
    print(f"[FAIL] CONTRACT_VIOLATION: {context} caBundle does not include the active SPIRE root", file=sys.stderr)
    raise SystemExit(2)

for pem in actual_certs:
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(pem)
        cert_path = handle.name
    try:
        proc = subprocess.run(
            ["openssl", "x509", "-in", cert_path, "-noout", "-issuer", "-nameopt", "RFC2253"],
            capture_output=True,
            text=True,
            check=False,
        )
    finally:
        pathlib.Path(cert_path).unlink(missing_ok=True)
    if proc.returncode != 0:
        print(proc.stderr.strip() or proc.stdout.strip() or f"[FAIL] CONTRACT_VIOLATION: unable to inspect {context} caBundle issuer", file=sys.stderr)
        raise SystemExit(2)
    issuer = proc.stdout.strip().split("=", 1)[-1].strip().upper()
    if "SPIRE" not in issuer and "SPIFFE" not in issuer:
        print(f"[FAIL] CONTRACT_VIOLATION: {context} caBundle issuer is not SPIRE/SPIFFE: {issuer}", file=sys.stderr)
        raise SystemExit(2)
    if "THREADFORGE-ROOT" in issuer or "CERT-MANAGER" in issuer:
        print(f"[FAIL] CONTRACT_VIOLATION: {context} caBundle issuer is cert-manager/threadforge-root rooted: {issuer}", file=sys.stderr)
        raise SystemExit(2)
PY
}

verify_converged_state() {
  local spire_root_active_pem_tmp="$1"
  local expected_root_b64 expected_pem root_subject
  local live_dir live_spire_csr_ca_cert live_spire_csr_ca_key live_spire_csr_tls_chain live_spire_csr_tls_key
  local live_cacerts_ca_cert live_cacerts_ca_key live_cacerts_cert_chain live_cacerts_root_cert
  local live_istiod_tls_chain live_istiod_tls_key live_istiod_ca_cert
  local live_spire_bundle_pem
  local webhook webhook_json_tmp ca_bundle live_issuer live_subject expected_issuer actual_count
  local expected_root_fp actual_root_fp expected_root_serial actual_root_serial expected_root_tmp actual_root_tmp

  expected_root_b64="$(base64 -w0 "$spire_root_active_pem_tmp" | tr -d '\n')"
  expected_pem="$(tr -d '\r' < "$spire_root_active_pem_tmp")"
  root_subject="$(openssl x509 -in "$spire_root_active_pem_tmp" -noout -subject | sed 's/^subject= *//')"
  expected_root_fp="$(openssl x509 -in "$spire_root_active_pem_tmp" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//')"
  expected_root_serial="$(openssl x509 -in "$spire_root_active_pem_tmp" -noout -serial | sed 's/^serial=//')"

  live_dir="$(mktemp -d)"
  live_spire_bundle_pem="${live_dir}/spire-bundle.pem"
  live_spire_csr_ca_cert="${live_dir}/spire-csr-ca.crt"
  live_spire_csr_ca_key="${live_dir}/spire-csr-ca.key"
  live_spire_csr_tls_chain="${live_dir}/spire-csr-ca-chain.crt"
  live_spire_csr_tls_key="${live_dir}/spire-csr-ca.key.pem"
  live_cacerts_ca_cert="${live_dir}/cacerts-ca.crt"
  live_cacerts_ca_key="${live_dir}/cacerts-ca.key"
  live_cacerts_cert_chain="${live_dir}/cacerts-chain.crt"
  live_cacerts_root_cert="${live_dir}/cacerts-root.crt"
  live_istiod_tls_chain="${live_dir}/istiod-chain.crt"
  live_istiod_tls_key="${live_dir}/istiod.key"
  live_istiod_ca_cert="${live_dir}/istiod-ca.crt"

  json_secret_field istio-system spire-csr-ca 'ca.crt' | base64 -d >"$live_spire_csr_ca_cert" || fail "spire-csr-ca secret missing ca.crt"
  json_secret_field istio-system spire-csr-ca 'ca.key' | base64 -d >"$live_spire_csr_ca_key" || fail "spire-csr-ca secret missing ca.key"
  json_secret_field istio-system spire-csr-ca 'tls.crt' | base64 -d >"$live_spire_csr_tls_chain" || fail "spire-csr-ca secret missing tls.crt"
  json_secret_field istio-system spire-csr-ca 'tls.key' | base64 -d >"$live_spire_csr_tls_key" || fail "spire-csr-ca secret missing tls.key"

  json_secret_field istio-system cacerts 'ca-cert.pem' | base64 -d >"$live_cacerts_ca_cert" || fail "cacerts secret missing ca-cert.pem"
  json_secret_field istio-system cacerts 'ca-key.pem' | base64 -d >"$live_cacerts_ca_key" || fail "cacerts secret missing ca-key.pem"
  json_secret_field istio-system cacerts 'cert-chain.pem' | base64 -d >"$live_cacerts_cert_chain" || fail "cacerts secret missing cert-chain.pem"
  json_secret_field istio-system cacerts 'root-cert.pem' | base64 -d >"$live_cacerts_root_cert" || fail "cacerts secret missing root-cert.pem"

  json_secret_field istio-system istiod-tls 'tls.crt' | base64 -d >"$live_istiod_tls_chain" || fail "istiod-tls secret missing tls.crt"
  json_secret_field istio-system istiod-tls 'tls.key' | base64 -d >"$live_istiod_tls_key" || fail "istiod-tls secret missing tls.key"
  json_secret_field istio-system istiod-tls 'ca.crt' | base64 -d >"$live_istiod_ca_cert" || fail "istiod-tls secret missing ca.crt"
  load_live_spire_bundle >"$live_spire_bundle_pem" || fail "unable to read live SPIRE bundle"

  live_issuer="$(openssl x509 -in "$live_spire_csr_ca_cert" -noout -issuer | sed 's/^issuer= *//')"
  [[ "$live_issuer" == "$root_subject" ]] || fail "spire-csr-ca ca.crt is not issued by the active SPIRE root"
  openssl verify -CAfile "$spire_root_active_pem_tmp" "$live_spire_csr_ca_cert" >/dev/null 2>&1 || fail "spire-csr-ca ca.crt does not verify against the active SPIRE root"
  [[ "$(openssl x509 -in "$live_spire_csr_ca_cert" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')" == "$(openssl pkey -in "$live_spire_csr_ca_key" -pubout -outform DER | sha256sum | awk '{print $1}')" ]] || fail "spire-csr-ca ca.key does not match ca.crt"
  live_subject="$(openssl x509 -in "$live_spire_csr_tls_chain" -noout -subject | sed 's/^subject= *//')"
  expected_issuer="$(openssl x509 -in "$live_spire_csr_ca_cert" -noout -subject | sed 's/^subject= *//')"
  [[ "$(openssl x509 -in "$live_spire_csr_tls_chain" -noout -issuer | sed 's/^issuer= *//')" == "$expected_issuer" ]] || fail "spire-csr-ca tls.crt is not issued by the spire-csr intermediate"
  actual_count="$(grep -c 'BEGIN CERTIFICATE' "$live_spire_csr_tls_chain" || true)"
  [[ "$actual_count" -ge 2 ]] || fail "spire-csr-ca tls.crt does not contain the expected certificate chain"
  [[ "$(openssl x509 -in "$live_spire_csr_tls_chain" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')" == "$(openssl pkey -in "$live_spire_csr_tls_key" -pubout -outform DER | sha256sum | awk '{print $1}')" ]] || fail "spire-csr-ca tls.key does not match tls.crt"

  [[ "$(openssl x509 -in "$live_cacerts_ca_cert" -noout -issuer | sed 's/^issuer= *//')" == "$root_subject" ]] || fail "cacerts ca-cert.pem is not issued by the active SPIRE root"
  openssl verify -CAfile "$spire_root_active_pem_tmp" "$live_cacerts_ca_cert" >/dev/null 2>&1 || fail "cacerts ca-cert.pem does not verify against the active SPIRE root"
  [[ "$(openssl x509 -in "$live_cacerts_ca_cert" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')" == "$(openssl pkey -in "$live_cacerts_ca_key" -pubout -outform DER | sha256sum | awk '{print $1}')" ]] || fail "cacerts ca-key.pem does not match ca-cert.pem"
  cat "$live_cacerts_ca_cert" "$spire_root_active_pem_tmp" >"$live_dir/expected-cacerts-chain.pem"
  diff -q "$live_dir/expected-cacerts-chain.pem" "$live_cacerts_cert_chain" >/dev/null 2>&1 || fail "cacerts cert-chain.pem does not match the live intermediate plus active SPIRE root"
  diff -q "$spire_root_active_pem_tmp" "$live_cacerts_root_cert" >/dev/null 2>&1 || fail "cacerts root-cert.pem does not match the active SPIRE root"

  [[ "$(openssl x509 -in "$live_istiod_ca_cert" -noout -subject | sed 's/^subject= *//')" == "$root_subject" ]] || fail "istiod-tls ca.crt does not match the active SPIRE root subject"
  diff -q "$spire_root_active_pem_tmp" "$live_istiod_ca_cert" >/dev/null 2>&1 || fail "istiod-tls ca.crt does not match the active SPIRE root"
  [[ "$(openssl x509 -in "$live_istiod_tls_chain" -noout -issuer | sed 's/^issuer= *//')" == "$root_subject" ]] || fail "istiod-tls tls.crt is not issued by the active SPIRE root"
  [[ "$(openssl x509 -in "$live_istiod_tls_chain" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')" == "$(openssl pkey -in "$live_istiod_tls_key" -pubout -outform DER | sha256sum | awk '{print $1}')" ]] || fail "istiod-tls tls.key does not match tls.crt"

  if [[ "$(json_configmap_field spire-system spire-ca-root-cert 'root-cert.pem')" != "$expected_pem" ]]; then
    fail "spire-ca-root-cert configmap does not match active SPIRE root"
  fi
  if [[ "$(json_configmap_field istio-system spire-ca-root-cert 'root-cert.pem')" != "$expected_pem" ]]; then
    fail "istio-system/spire-ca-root-cert configmap does not match active SPIRE root"
  fi
  if [[ "$(json_configmap_field istio-system istio-ca-root-cert 'root-cert.pem')" != "$expected_pem" ]]; then
    fail "istio-ca-root-cert configmap does not match active SPIRE root"
  fi
  if [[ "$(json_configmap_field observability istio-ca-root-cert 'root-cert.pem')" != "$expected_pem" ]]; then
    fail "observability/istio-ca-root-cert configmap does not match active SPIRE root"
  fi

  live_subject="$(
    kubectl -n istio-system get deployment istiod -o json 2>/dev/null | jq -r '
      .spec.template.spec.volumes[]?
      | select(.name == "istio-csr-ca-configmap")
      | .configMap.name
    ' | head -n1
  )"
  [[ "$live_subject" == "spire-ca-root-cert" ]] || fail "istiod deployment is not sourced from spire-ca-root-cert"

  for webhook in $(kubectl get mutatingwebhookconfiguration -o name 2>/dev/null | grep -i istio | sed 's|.*/||' || true); do
    webhook_json_tmp="$(mktemp)"
    kubectl get mutatingwebhookconfiguration "$webhook" -o json >"$webhook_json_tmp"
    ca_bundle="$(jq -r '.webhooks[]?.clientConfig.caBundle // empty' "$webhook_json_tmp" | head -n1)"
    rm -f "$webhook_json_tmp"
    [[ -n "$ca_bundle" ]] || fail "mutating webhook ${webhook} missing caBundle"
    actual_root_tmp="$(mktemp)"
    printf '%s' "$ca_bundle" | base64 -d >"$actual_root_tmp" 2>/dev/null || true
    bundle_includes_active_root_and_is_spire_issued "$spire_root_active_pem_tmp" "$actual_root_tmp" "mutating webhook ${webhook}"
    rm -f "$actual_root_tmp"
  done

  for webhook in istio-validator-istio-system istiod-default-validator; do
    if kubectl get validatingwebhookconfiguration "$webhook" >/dev/null 2>&1; then
      webhook_json_tmp="$(mktemp)"
      kubectl get validatingwebhookconfiguration "$webhook" -o json >"$webhook_json_tmp"
      ca_bundle="$(jq -r '.webhooks[]?.clientConfig.caBundle // empty' "$webhook_json_tmp" | head -n1)"
      rm -f "$webhook_json_tmp"
      [[ -n "$ca_bundle" ]] || fail "validating webhook ${webhook} missing caBundle"
      actual_root_tmp="$(mktemp)"
      printf '%s' "$ca_bundle" | base64 -d >"$actual_root_tmp" 2>/dev/null || true
      bundle_includes_active_root_and_is_spire_issued "$spire_root_active_pem_tmp" "$actual_root_tmp" "validating webhook ${webhook}"
      rm -f "$actual_root_tmp"
    fi
  done

  kubectl -n istio-system get secret istio-ca-secret >/dev/null 2>&1 && fail "stale istio-ca-secret is still present"
  kubectl -n istio-system get configmap threadforge-root-ca >/dev/null 2>&1 && fail "stale threadforge-root-ca configmap is still present"

  rm -rf "$live_dir"
}

refresh_spire_csr_bridge_secrets() {
  local spire_root_pem_tmp spire_bundle_pem_tmp spire_root_key_der_tmp spire_root_key_pem_tmp spire_root_reader_pod
  local ca_crt_tmp ca_key_tmp ca_key_pkcs8_tmp ca_csr_tmp ca_ext_tmp
  local spire_csr_key_tmp spire_csr_csr_tmp spire_csr_crt_tmp spire_csr_ext_tmp spire_csr_chain_tmp
  local istiod_key_tmp istiod_csr_tmp istiod_crt_tmp istiod_ext_tmp istiod_chain_tmp cert_chain_tmp
  local spire_keys_json_tmp spire_csr_ca_yaml_tmp cacerts_yaml_tmp istiod_tls_yaml_tmp
  local openssl_serial_dir spire_root_serial_tmp spire_csr_serial_tmp istiod_serial_tmp

  spire_root_pem_tmp="$(mktemp)"
  spire_bundle_pem_tmp="$(mktemp)"
  SPIRE_BUNDLE_PEM_FILE="$spire_bundle_pem_tmp"
  spire_root_key_der_tmp="$(mktemp)"
  spire_root_key_pem_tmp="$(mktemp)"
  ca_crt_tmp="$(mktemp)"
  ca_key_tmp="$(mktemp)"
  ca_key_pkcs8_tmp="$(mktemp)"
  ca_csr_tmp="$(mktemp)"
  ca_ext_tmp="$(mktemp)"
  spire_csr_key_tmp="$(mktemp)"
  spire_csr_csr_tmp="$(mktemp)"
  spire_csr_crt_tmp="$(mktemp)"
  spire_csr_ext_tmp="$(mktemp)"
  spire_csr_chain_tmp="$(mktemp)"
  istiod_key_tmp="$(mktemp)"
  istiod_csr_tmp="$(mktemp)"
  istiod_crt_tmp="$(mktemp)"
  istiod_ext_tmp="$(mktemp)"
  istiod_chain_tmp="$(mktemp)"
  cert_chain_tmp="$(mktemp)"
  spire_keys_json_tmp="$(mktemp)"
  spire_csr_ca_yaml_tmp="$(mktemp)"
  cacerts_yaml_tmp="$(mktemp)"
  istiod_tls_yaml_tmp="$(mktemp)"
  openssl_serial_dir="$(mktemp -d)"
  spire_root_serial_tmp="${openssl_serial_dir}/spire-root.srl"
  spire_csr_serial_tmp="${openssl_serial_dir}/spire-csr.srl"
  istiod_serial_tmp="${openssl_serial_dir}/istiod.srl"
  load_active_root_from_state >"${spire_root_pem_tmp}" \
    || fail "unable to read active SPIRE root from trust authority state"
  load_live_spire_bundle >"${spire_bundle_pem_tmp}" \
    || fail "unable to read live SPIRE bundle"
  if ! proof_mode_active; then
    bash "$REPO_ROOT/scripts/infra/ensure_spire_root_key_reader.sh" \
      || fail "unable to ensure SPIRE root-key reader pod"
  fi

  # Select the authoritative active root from the live SPIRE bundle, then pair
  # it with the matching x509-CA key material from SPIRE's key manager.
  spire_root_reader_pod=""
  spire_select_err=""
  while IFS=$'\t' read -r _ candidate_pod; do
    [[ -n "$candidate_pod" ]] || continue
    if kubectl exec -n spire-system "${candidate_pod}" -c reader -- cat /run/spire/data/keys.json >"${spire_keys_json_tmp}" 2>/dev/null; then
      if spire_select_err="$({ python3 - "${spire_root_pem_tmp}" "${spire_keys_json_tmp}" "${spire_root_pem_tmp}.active" "${spire_root_key_der_tmp}" "${spire_root_serial_tmp}" <<'PY'
import base64, hashlib, json, pathlib, subprocess, sys, tempfile

active_root_path, keys_path, out_cert_path, out_key_der_path, out_meta_path = sys.argv[1:]

active_pem = str(pathlib.Path(active_root_path).read_text(encoding="utf-8") or "").strip()
if not active_pem:
	print("[FAIL] live SPIRE bundle root certificate missing", file=sys.stderr)
	raise SystemExit(1)

def pubkey_fp(pem_bytes):
	result = subprocess.run(
		["openssl", "x509", "-pubkey", "-noout"],
		input=pem_bytes,
		capture_output=True,
		text=False,
	)
	if result.returncode != 0:
		return None
	fp_result = subprocess.run(
		["openssl", "pkey", "-pubin", "-pubout", "-outform", "DER"],
		input=result.stdout,
		capture_output=True,
	)
	if fp_result.returncode != 0:
		return None
	return hashlib.sha256(fp_result.stdout).hexdigest()

active_fp = pubkey_fp(active_pem.encode())
if not active_fp:
	print("[FAIL] unable to compute active root public key fingerprint", file=sys.stderr)
	raise SystemExit(1)

keys_data = json.loads(pathlib.Path(keys_path).read_text(encoding="utf-8"))
matched_key_der = None
matched_key_name = None
for key_name, key_b64 in keys_data.get("keys", {}).items():
	if not key_name.startswith("x509-CA"):
		continue
	try:
		key_der = base64.b64decode(key_b64)
	except Exception:
		continue
	with tempfile.NamedTemporaryFile(suffix=".der", delete=False) as fh:
		fh.write(key_der)
		kpath = fh.name
	pem_result = subprocess.run(
		["openssl", "pkey", "-inform", "DER", "-in", kpath, "-pubout", "-outform", "PEM"],
		capture_output=True,
	)
	pathlib.Path(kpath).unlink(missing_ok=True)
	if pem_result.returncode != 0:
		continue
	fp_result = subprocess.run(
		["openssl", "pkey", "-pubin", "-pubout", "-outform", "DER"],
		input=pem_result.stdout,
		capture_output=True,
	)
	if fp_result.returncode != 0:
		continue
	candidate_fp = hashlib.sha256(fp_result.stdout).hexdigest()
	if candidate_fp == active_fp:
		matched_key_der = key_der
		matched_key_name = key_name
		break

if matched_key_der is None:
	print("[FAIL] no key in SPIRE keys.json matches active root public key", file=sys.stderr)
	raise SystemExit(1)

pathlib.Path(out_cert_path).write_text(active_pem)
pathlib.Path(out_key_der_path).write_bytes(matched_key_der)
pathlib.Path(out_meta_path).write_text(
	f"active_root_pubkey_sha256={active_fp}\n"
	f"matched_key_name={matched_key_name}\n"
)
PY
} 2>&1)"; then
        spire_root_reader_pod="${candidate_pod}"
        break
      fi
    fi
  done < <(
    kubectl get pods -n spire-system -o json 2>/dev/null | jq -r '
      .items[]
      | select(.metadata.name | startswith("spire-root-key-reader"))
      | select(.status.phase == "Running")
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | [.metadata.creationTimestamp, .metadata.name]
      | @tsv
    ' | sort -r
  )
  [[ -n "$spire_root_reader_pod" ]] || {
    echo "[FAIL] unable to match active SPIRE root and key from SPIRE bundle"
    if [[ -n "${spire_select_err}" ]]; then
      printf '%s\n' "${spire_select_err}" | sed 's/^/[FAIL] /'
    fi
    exit 2
  }

  local spire_root_active_pem_tmp
  spire_root_active_pem_tmp="${spire_root_pem_tmp}.active"
  ACTIVE_ROOT_PEM_FILE="$spire_root_active_pem_tmp"
  openssl ec -inform DER -in "${spire_root_key_der_tmp}" -out "${spire_root_key_pem_tmp}" >/dev/null 2>&1 \
    || fail "unable to convert SPIRE x509 CA signing key"

  openssl genrsa -out "$ca_key_tmp" 2048 >/dev/null 2>&1 || fail "failed to generate spire-csr intermediate key"
  cat >"$ca_ext_tmp" <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign,digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

  openssl req -new -key "$ca_key_tmp" \
    -subj "/C=US/O=SPIRE/CN=spire-csr-intermediate" \
    -out "$ca_csr_tmp" >/dev/null 2>&1 || fail "failed to generate spire-csr intermediate CSR"

  openssl_sign_request "$ca_csr_tmp" "$spire_root_active_pem_tmp" "${spire_root_key_pem_tmp}" "${spire_root_serial_tmp}" \
    "$ca_crt_tmp" 365 "$ca_ext_tmp" >/dev/null 2>&1 || fail "failed to sign spire-csr intermediate"

  openssl pkcs8 -topk8 -nocrypt -in "$ca_key_tmp" -out "$ca_key_pkcs8_tmp" >/dev/null 2>&1 || fail "failed to convert intermediate key"

  openssl genrsa -out "$spire_csr_key_tmp" 2048 >/dev/null 2>&1 || fail "failed to generate spire-csr serving key"
  cat >"$spire_csr_ext_tmp" <<'EOF'
subjectAltName=DNS:spire-csr,DNS:spire-csr.istio-system.svc,DNS:spire-csr.istio-system.svc.cluster.local
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
basicConstraints=critical,CA:FALSE
EOF

  openssl req -new -key "$spire_csr_key_tmp" \
    -subj "/CN=spire-csr.istio-system.svc.cluster.local" \
    -out "$spire_csr_csr_tmp" >/dev/null 2>&1 || fail "failed to generate spire-csr serving CSR"

  openssl_sign_request "$spire_csr_csr_tmp" "$ca_crt_tmp" "$ca_key_tmp" "${spire_csr_serial_tmp}" \
    "$spire_csr_crt_tmp" 365 "$spire_csr_ext_tmp" >/dev/null 2>&1 || fail "failed to sign spire-csr serving certificate"

  openssl genrsa -out "$istiod_key_tmp" 2048 >/dev/null 2>&1 || fail "failed to generate istiod serving key"
  cat >"$istiod_ext_tmp" <<'EOF'
subjectAltName=DNS:istiod,DNS:istiod.istio-system.svc,DNS:istiod.istio-system.svc.cluster.local
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
basicConstraints=critical,CA:FALSE
EOF

  openssl req -new -key "$istiod_key_tmp" \
    -subj "/CN=istiod.istio-system.svc.cluster.local" \
    -out "$istiod_csr_tmp" >/dev/null 2>&1 || fail "failed to generate istiod serving CSR"

  openssl_sign_request "$istiod_csr_tmp" "$spire_root_active_pem_tmp" "${spire_root_key_pem_tmp}" "${istiod_serial_tmp}" \
    "$istiod_crt_tmp" 365 "$istiod_ext_tmp" >/dev/null 2>&1 || fail "failed to sign istiod serving certificate"

  cat "$ca_crt_tmp" "$spire_root_active_pem_tmp" >"$cert_chain_tmp"
  cat "$spire_csr_crt_tmp" "$ca_crt_tmp" >"$spire_csr_chain_tmp"
  cp "$istiod_crt_tmp" "$istiod_chain_tmp"

  if proof_mode_active; then
    verify_converged_state \
      "$spire_root_active_pem_tmp" \
      "$ca_crt_tmp" \
      "$ca_key_pkcs8_tmp" \
      "$spire_csr_chain_tmp" \
      "$spire_csr_key_tmp" \
      "$cert_chain_tmp" \
      "$istiod_chain_tmp" \
      "$istiod_key_tmp"
    rm -f "$spire_root_pem_tmp" "$spire_root_key_der_tmp" "$spire_root_key_pem_tmp" "$ca_crt_tmp" "$ca_key_tmp" "$ca_key_pkcs8_tmp" "$ca_csr_tmp" "$ca_ext_tmp" \
      "$spire_csr_key_tmp" "$spire_csr_csr_tmp" "$spire_csr_crt_tmp" "$spire_csr_ext_tmp" "$spire_csr_chain_tmp" \
      "$istiod_key_tmp" "$istiod_csr_tmp" "$istiod_crt_tmp" "$istiod_ext_tmp" "$istiod_chain_tmp" "$cert_chain_tmp" "$spire_keys_json_tmp" \
      "$spire_csr_ca_yaml_tmp" "$cacerts_yaml_tmp" "$istiod_tls_yaml_tmp" \
      "$spire_root_serial_tmp" "$spire_csr_serial_tmp" "$istiod_serial_tmp"
    rm -rf "$openssl_serial_dir"
    return 0
  fi

  kubectl -n istio-system create secret generic spire-csr-ca \
    --from-file=ca.crt="$ca_crt_tmp" \
    --from-file=ca.key="$ca_key_pkcs8_tmp" \
    --from-file=tls.crt="$spire_csr_chain_tmp" \
    --from-file=tls.key="$spire_csr_key_tmp" \
    --dry-run=client -o yaml >"$spire_csr_ca_yaml_tmp"
  if kubectl -n istio-system get secret spire-csr-ca >/dev/null 2>&1; then
    kubectl replace -f "$spire_csr_ca_yaml_tmp" >/dev/null
  else
    kubectl create -f "$spire_csr_ca_yaml_tmp" >/dev/null
  fi

  kubectl -n istio-system create secret generic cacerts \
    --from-file=ca-cert.pem="$ca_crt_tmp" \
    --from-file=ca-key.pem="$ca_key_pkcs8_tmp" \
    --from-file=cert-chain.pem="$cert_chain_tmp" \
    --from-file=root-cert.pem="$spire_root_active_pem_tmp" \
    --dry-run=client -o yaml >"$cacerts_yaml_tmp"
  if kubectl -n istio-system get secret cacerts >/dev/null 2>&1; then
    kubectl replace -f "$cacerts_yaml_tmp" >/dev/null
  else
    kubectl create -f "$cacerts_yaml_tmp" >/dev/null
  fi

  kubectl -n istio-system create secret generic istiod-tls \
    --from-file=tls.crt="$istiod_chain_tmp" \
    --from-file=tls.key="$istiod_key_tmp" \
    --from-file=ca.crt="$spire_root_active_pem_tmp" \
    --dry-run=client -o yaml >"$istiod_tls_yaml_tmp"
  if kubectl -n istio-system get secret istiod-tls >/dev/null 2>&1; then
    kubectl replace -f "$istiod_tls_yaml_tmp" >/dev/null
  else
    kubectl create -f "$istiod_tls_yaml_tmp" >/dev/null
  fi

  rm -f "$spire_root_pem_tmp" "$spire_root_key_der_tmp" "$spire_root_key_pem_tmp" "$ca_crt_tmp" "$ca_key_tmp" "$ca_key_pkcs8_tmp" "$ca_csr_tmp" "$ca_ext_tmp" \
    "$spire_csr_key_tmp" "$spire_csr_csr_tmp" "$spire_csr_crt_tmp" "$spire_csr_ext_tmp" "$spire_csr_chain_tmp" \
    "$istiod_key_tmp" "$istiod_csr_tmp" "$istiod_crt_tmp" "$istiod_ext_tmp" "$istiod_chain_tmp" "$cert_chain_tmp" "$spire_keys_json_tmp" \
    "$spire_csr_ca_yaml_tmp" "$cacerts_yaml_tmp" "$istiod_tls_yaml_tmp" \
    "$spire_root_serial_tmp" "$spire_csr_serial_tmp" "$istiod_serial_tmp"
  rm -rf "$openssl_serial_dir"
}

reconcile_root_configmaps() {
  local root_tmp active_root_pem configmap_yaml_tmp
  root_tmp="$(mktemp)"
  configmap_yaml_tmp="$(mktemp)"

  active_root_pem="$(jq -r '.active_root_pem // empty' "$TRUST_AUTHORITY_STATE_FILE" 2>/dev/null || true)"
  [[ -n "$active_root_pem" ]] || fail "active SPIRE root PEM unavailable"
  printf '%s\n' "$active_root_pem" >"$root_tmp"

  for target in "spire-system/spire-ca-root-cert" "istio-system/spire-ca-root-cert" "istio-system/istio-ca-root-cert" "observability/istio-ca-root-cert"; do
    ns="${target%%/*}"
    name="${target#*/}"
    kubectl create configmap "$name" --from-file=root-cert.pem="$root_tmp" -n "$ns" --dry-run=client -o yaml >"$configmap_yaml_tmp"
    if kubectl -n "$ns" get configmap "$name" >/dev/null 2>&1; then
      kubectl replace -f "$configmap_yaml_tmp" >/dev/null
    else
      kubectl create -f "$configmap_yaml_tmp" >/dev/null
    fi
  done

  kubectl -n istio-system label configmap istio-ca-root-cert istio.io/config=true --overwrite >/dev/null 2>&1 || true
  rm -f "$root_tmp" "$configmap_yaml_tmp"
}

set_istiod_root_source() {
  kubectl -n istio-system get deployment istiod -o json \
    | jq '
      (.spec.template.spec.volumes[] | select(.name == "istio-csr-ca-configmap") | .configMap.name) = "spire-ca-root-cert"
      | del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .status)
    ' \
    | kubectl replace -f - >/dev/null
}

reconcile_webhook_cabundle() {
  local live_bundle_pem bundle_b64_file webhook_json_tmp webhook validating_list vwh ca_bundle

  live_bundle_pem="$(mktemp)"

  bundle_b64_file="$(mktemp)"
  webhook_json_tmp="$(mktemp)"

  load_live_spire_bundle >"$live_bundle_pem" || fail "authoritative SPIRE bundle unavailable"
  base64 -w0 "$live_bundle_pem" >"$bundle_b64_file"
  ca_bundle="$(tr -d '\n' <"$bundle_b64_file")"

  while IFS= read -r webhook; do
    [[ -n "$webhook" ]] || continue
    kubectl get mutatingwebhookconfiguration "$webhook" -o json >"$webhook_json_tmp"
    jq --arg ca "$ca_bundle" '
      (.webhooks[]?.clientConfig.caBundle) = $ca
      | del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .status)
    ' "$webhook_json_tmp" >"$webhook_json_tmp.reconciled"
    kubectl delete mutatingwebhookconfiguration "$webhook" --ignore-not-found >/dev/null 2>&1 || true
    kubectl create -f "$webhook_json_tmp.reconciled" >/dev/null \
      || fail "failed to update mutating webhook configuration ${webhook}"
  done < <(kubectl get mutatingwebhookconfiguration -o name 2>/dev/null | grep -i istio | sed 's|.*/||' || true)

  validating_list="istio-validator-istio-system istiod-default-validator"
  for vwh in $validating_list; do
    if kubectl get validatingwebhookconfiguration "$vwh" >/dev/null 2>&1; then
      kubectl get validatingwebhookconfiguration "$vwh" -o json >"$webhook_json_tmp"
      jq --arg ca "$ca_bundle" '
        (.webhooks[]?.clientConfig.caBundle) = $ca
        | del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .status)
      ' "$webhook_json_tmp" >"$webhook_json_tmp.reconciled"
      kubectl delete validatingwebhookconfiguration "$vwh" --ignore-not-found >/dev/null 2>&1 || true
      kubectl create -f "$webhook_json_tmp.reconciled" >/dev/null \
        || fail "failed to update validating webhook configuration ${vwh}"
    fi
  done

  rm -f "$bundle_b64_file" "$webhook_json_tmp" "$webhook_json_tmp.reconciled"
  rm -f "$live_bundle_pem"
}


remove_stale_ca_sources() {
  # Legacy/fallback CA sources are forbidden.
  kubectl -n istio-system delete secret istio-ca-secret threadforge-root-ca --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n istio-system delete configmap threadforge-root-ca --ignore-not-found >/dev/null 2>&1 || true
}

reset_spire_csr_pod() {
  kubectl delete pod -n istio-system -l app=spire-csr --ignore-not-found >/dev/null
  kubectl -n istio-system rollout status deployment/spire-csr --timeout="${SPIRE_ROLLOUT_TIMEOUT}s" >/dev/null
}

drop_spire_csr_init_gate() {
  kubectl -n istio-system patch deployment spire-csr --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/initContainers"}]' >/dev/null 2>&1 || true
}

refresh_trust_root_artifact() {
  # The canonical trust-refresh owner keeps the proof baseline aligned with the
  # active SPIRE root so proof can witness rather than repair stale state.
  TRUST_ROOT_PHASE=capture bash "$REPO_ROOT/scripts/verify/verify_trust_root_immutability.sh" \
    >/dev/null \
    || fail "failed to refresh trust root artifact after SPIRE->Istio CA path refresh"
}

main() {
  echo "[converge] refreshing SPIRE->Istio CA path from active SPIRE root"
  if proof_mode_active; then
    refresh_spire_csr_bridge_secrets
    return 0
  fi

  bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
  refresh_spire_csr_bridge_secrets
  reconcile_root_configmaps
  set_istiod_root_source
  kubectl -n istio-system rollout restart deployment/istiod >/dev/null
  kubectl -n istio-system rollout status deployment/istiod --timeout="${SPIRE_ROLLOUT_TIMEOUT}s" >/dev/null
  reconcile_webhook_cabundle
  remove_stale_ca_sources
  drop_spire_csr_init_gate

  # Force new spire-csr process after secrets/configmaps replacement.
  reset_spire_csr_pod

  # Keep identity registrations deterministic after control-plane refresh.
  SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "$REPO_ROOT/scripts/proof/reconcile_spire_entries.sh" >/dev/null \
    || fail "failed to reconcile SPIRE entries after CA path refresh"

  refresh_trust_root_artifact

  echo "[converge] SPIRE->Istio CA path refresh complete"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
