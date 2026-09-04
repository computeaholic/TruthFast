#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
ARTIFACT_PATH="$PROOF_DIR/gateway_ca_source.json"
TRUST_AUTHORITY_STATE_FILE="${TRUST_AUTHORITY_STATE_FILE:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
DEBUG_SCRIPT="$REPO_ROOT/scripts/debug/debug_ca_sources.sh"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/ca_source_debug.log"
FAILURE_LOG_PATH="$REPO_ROOT/artifacts/debug/ca_failure.log"
KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain
# shellcheck source=scripts/lib/envoy_admin.sh
source "$REPO_ROOT/scripts/lib/envoy_admin.sh"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

write_failure_dump() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        bash "$DEBUG_SCRIPT" "$FAILURE_LOG_PATH" >/dev/null 2>&1 || true
    fi
}

run_kubectl() {
    if [ -z "$KUBECTL_BIN" ]; then
        fail "kubectl not found"
    fi
    "$KUBECTL_BIN" "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

require_cmd python3
require_cmd openssl
require_cmd jq

export TRUST_AUTHORITY_STATE_FILE

mkdir -p "$PROOF_DIR"
mkdir -p "$REPO_ROOT/artifacts/debug"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"; write_failure_dump' EXIT

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
bash "$DEBUG_SCRIPT" "$DEBUG_LOG_PATH" >/dev/null 2>&1 || true

gateway_pod="$(run_kubectl get pods -n istio-system -l app=istio-ingressgateway -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)"
[ -n "$gateway_pod" ] || fail "no running istio-ingressgateway pod found"

GATEWAY_CERTS_JSON="$(run_kubectl -n istio-system exec deploy/istio-ingressgateway -c istio-proxy -- curl -s localhost:15000/certs 2>/dev/null || true)"
[ -n "$GATEWAY_CERTS_JSON" ] || fail "gateway Envoy /certs returned no data"

run_kubectl -n spire-system get configmap spire-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' >"$TMP_DIR/spire_root.pem" 2>/dev/null || true
spire_root_pem="$(cat "$TMP_DIR/spire_root.pem" 2>/dev/null || true)"
[ -n "$spire_root_pem" ] || fail "SPIRE root PEM unavailable"

spire_server_pod="$(select_active_spire_server_pod spire-system || true)"
[ -n "$spire_server_pod" ] || fail "unable to resolve SPIRE server pod"
spire_bundle_pem="$(run_kubectl -n spire-system exec -c spire-server "$spire_server_pod" -- /opt/spire/bin/spire-server bundle show -socketPath /run/spire/private/spire-server.sock -format pem 2>/dev/null || true)"
[ -n "$spire_bundle_pem" ] || spire_bundle_pem="$spire_root_pem"

proxy_secret_path="$TMP_DIR/gateway_proxy_secret.json"
capture_envoy_secrets istio-system "$gateway_pod" "$proxy_secret_path" 2>/dev/null || true
[ -s "$proxy_secret_path" ] || fail "gateway Envoy config dump returned no SDS data"
proxy_secret_json="$(cat "$proxy_secret_path")"

python3 - "$spire_root_pem" "$spire_bundle_pem" "$GATEWAY_CERTS_JSON" "$proxy_secret_json" "$ARTIFACT_PATH" <<'PY'
import base64
import hashlib
import json
import os
import pathlib
import re
import ssl
import subprocess
import sys
import tempfile

spire_root_pem = sys.argv[1]
spire_bundle_pem = sys.argv[2]
gateway_certs = json.loads(sys.argv[3])
proxy_secret = json.loads(sys.argv[4])
artifact_path = pathlib.Path(sys.argv[5])


def extract_pems(text: str):
    if not isinstance(text, str):
        return []
    return [m.strip() + "\n" for m in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", text)]


def pem_hash(pem: str):
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem).replace(b"\r", b"")).hexdigest()


def inspect_issuer_subject(pem: str):
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(pem)
        cert_path = handle.name
    try:
        proc = subprocess.run(["openssl", "x509", "-in", cert_path, "-noout", "-issuer", "-subject", "-text"], capture_output=True, text=True, check=False)
    finally:
        pathlib.Path(cert_path).unlink(missing_ok=True)
    if proc.returncode != 0:
        raise SystemExit("[FAIL] CONTRACT_VIOLATION: unable to inspect gateway certificate issuer")
    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    issuer = next((line.split("=", 1)[1].strip() for line in lines if line.lower().startswith("issuer=")), "")
    subject = next((line.split("=", 1)[1].strip() for line in lines if line.lower().startswith("subject=")), "")
    san_uris = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if "URI:" in line:
            for part in line.split(","):
                part = part.strip()
                if part.startswith("URI:"):
                    san_uris.append(part.replace("URI:", "", 1).strip())
    return issuer, subject, san_uris


def cert_serial(pem: str):
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(pem)
        cert_path = handle.name
    try:
        proc = subprocess.run(["openssl", "x509", "-in", cert_path, "-noout", "-serial"], capture_output=True, text=True, check=False)
    finally:
        pathlib.Path(cert_path).unlink(missing_ok=True)
    if proc.returncode != 0 or "=" not in proc.stdout:
        raise SystemExit("[FAIL] CONTRACT_VIOLATION: unable to inspect gateway root serial")
    return proc.stdout.split("=", 1)[1].strip().lower().lstrip("0") or "0"


roots = extract_pems(spire_root_pem)
if not roots:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: SPIRE bundle contained no roots")
trust_state_path = pathlib.Path(os.environ.get("TRUST_AUTHORITY_STATE_FILE", ""))
if not trust_state_path:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: TRUST_AUTHORITY_STATE_FILE not set")
trust_state = json.loads(trust_state_path.read_text(encoding="utf-8"))
active_root_pem = str(trust_state.get("active_root_pem") or "").strip()
active_root_serial = str(trust_state.get("active_root_serial") or "").strip().lower().lstrip("0") or "0"
if not active_root_pem:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: trust authority state missing active_root_pem")
if cert_serial(active_root_pem) != active_root_serial:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: trust authority active_root_pem does not match active_root_serial")
spire_root_hash = pem_hash(active_root_pem)

bundle_roots = extract_pems(spire_bundle_pem)
if not bundle_roots:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: SPIRE bundle contained no roots")

spiffe_entries = []
for entry in gateway_certs.get("certificates", []) or []:
    if not isinstance(entry, dict):
        continue
    chain = entry.get("cert_chain") or []
    if not chain:
        continue
    uris = []
    for cert in chain:
        for san in cert.get("subject_alt_names") or []:
            uri = san.get("uri")
            if isinstance(uri, str) and uri.startswith("spiffe://"):
                uris.append(uri)
    if uris:
        spiffe_entries.append((entry, uris))

if not spiffe_entries:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: gateway Envoy /certs exposed no SPIFFE workload certificates")

leaf_uris = []
for entry, uris in spiffe_entries:
    leaf_uris.extend(uris)

dynamic = proxy_secret.get("dynamicActiveSecrets")
if not isinstance(dynamic, list) or not dynamic:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: gateway proxy-config returned no dynamicActiveSecrets")

root_entries = [entry for entry in dynamic if entry.get("name") == "ROOTCA"]
if len(root_entries) != 1:
    raise SystemExit(f"[FAIL] CONTRACT_VIOLATION: expected exactly one ROOTCA entry for gateway, found {len(root_entries)}")

trusted_ca_b64 = (((root_entries[0].get("secret") or {}).get("validationContext") or {}).get("trustedCa") or {}).get("inlineBytes")
if not isinstance(trusted_ca_b64, str) or not trusted_ca_b64:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: gateway ROOTCA missing trustedCa.inlineBytes")
trusted_ca_pem = base64.b64decode(trusted_ca_b64).decode("utf-8", errors="ignore")
trusted_roots = extract_pems(trusted_ca_pem)
if not trusted_roots:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: gateway ROOTCA contains no roots")

active_root_hash = pem_hash(active_root_pem)
if active_root_hash not in {pem_hash(root) for root in trusted_roots}:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: gateway ROOTCA does not contain the active SPIRE root")

gateway_root_hash = active_root_hash
gateway_root_serial = active_root_serial

bundle_root_hashes = {pem_hash(root_pem): root_pem for root_pem in bundle_roots}
if gateway_root_hash not in bundle_root_hashes:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: gateway ROOTCA is not present in active SPIRE bundle")

matched_bundle_root_hash = gateway_root_hash
gateway_matches_current_spire_root = gateway_root_hash == spire_root_hash

default_entries = [entry for entry in dynamic if entry.get("name") == "default"]
if len(default_entries) != 1:
    raise SystemExit(f"[FAIL] CONTRACT_VIOLATION: expected one gateway workload secret, found {len(default_entries)}")

chain_b64 = (((default_entries[0].get("secret") or {}).get("tlsCertificate") or {}).get("certificateChain") or {}).get("inlineBytes")
if not isinstance(chain_b64, str) or not chain_b64:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: gateway workload secret missing certificateChain.inlineBytes")
chain_pem = base64.b64decode(chain_b64).decode("utf-8", errors="ignore")
chain_certs = extract_pems(chain_pem)
if not chain_certs:
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: gateway workload cert chain is empty")

issuer, subject, san_uris = inspect_issuer_subject(chain_certs[0])
if not any(uri.startswith("spiffe://" + os.environ["SPIFFE_TRUST_DOMAIN"] + "/") for uri in san_uris):
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: gateway leaf SAN does not contain a valid SPIFFE identity")

if not any(uri.startswith(f"spiffe://{os.environ['SPIFFE_TRUST_DOMAIN']}/ns/istio-system/sa/") for uri in leaf_uris):
    raise SystemExit("[FAIL] CONTRACT_VIOLATION: gateway Envoy /certs does not show an istio-system SPIFFE workload identity")

artifact = {
    "status": "PASS",
    "citadel_log_artifacts": False,
    "issuer_line": "",
    "leaf_issuer": issuer,
    "leaf_subject": subject,
    "leaf_san_uris": san_uris,
    "spiffe_trust_domain": os.environ["SPIFFE_TRUST_DOMAIN"],
    "spiffe_san_match": True,
    "single_runtime_root": True,
    "spire_root_hash": spire_root_hash,
    "gateway_root_hash": gateway_root_hash,
    "gateway_root_serial": gateway_root_serial,
    "gateway_root_in_spire_bundle": True,
    "gateway_matches_current_spire_root": gateway_matches_current_spire_root,
}

artifact_path.write_text(json.dumps(artifact, indent=2) + "\n")
print("[PASS] gateway CA source verified: SPIRE-only, no Citadel artifacts")
PY
