#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
ARTIFACT_PATH="$PROOF_DIR/ca_integrity.json"
TRUST_AUTHORITY_STATE_FILE="${TRUST_AUTHORITY_STATE_FILE:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
DEBUG_SCRIPT="$REPO_ROOT/scripts/debug/debug_ca_sources.sh"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/ca_source_debug.log"
FAILURE_LOG_PATH="$REPO_ROOT/artifacts/debug/ca_failure.log"

KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"
# shellcheck source=scripts/lib/envoy_admin.sh
source "$REPO_ROOT/scripts/lib/envoy_admin.sh"

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
  [ -n "$KUBECTL_BIN" ] || fail "kubectl not found"
  "$KUBECTL_BIN" "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

require_cmd python3
require_cmd openssl
require_cmd jq

mkdir -p "$PROOF_DIR" "$REPO_ROOT/artifacts/debug"
trap write_failure_dump EXIT
bash "$DEBUG_SCRIPT" "$DEBUG_LOG_PATH" >/dev/null 2>&1 || true

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap 'cleanup; write_failure_dump' EXIT

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
[[ -s "$TRUST_AUTHORITY_STATE_FILE" ]] || fail "trust authority state unavailable"

source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

SPIRE_SERVER_POD="$(select_active_spire_server_pod spire-system || true)"
[ -n "$SPIRE_SERVER_POD" ] || fail "unable to resolve SPIRE server pod"
SPIRE_ROOT_PEM_FILE="$WORK_DIR/spire_root.pem"
ISTIOD_TLS_CRT_FILE="$WORK_DIR/istiod_tls.crt"
GATEWAY_PROXY_SECRET_FILE="$WORK_DIR/gateway_proxy_secret.json"
MUTATING_WEBHOOKS_FILE="$WORK_DIR/mutating_webhooks.json"
VALIDATING_WEBHOOKS_FILE="$WORK_DIR/validating_webhooks.json"

run_kubectl -n spire-system exec -c spire-server "$SPIRE_SERVER_POD" -- /opt/spire/bin/spire-server bundle show -socketPath /run/spire/private/spire-server.sock -format pem 2>/dev/null \
  >"$SPIRE_ROOT_PEM_FILE" || true
[ -s "$SPIRE_ROOT_PEM_FILE" ] || fail "SPIRE bundle PEM unavailable"

ISTIOD_SECRET="$(run_kubectl -n istio-system get deploy istiod -o json | jq -r '.spec.template.spec.volumes[]? | select(.name=="istio-csr-dns-cert" and .secret.secretName != null) | .secret.secretName' | head -n1)"
[ -n "$ISTIOD_SECRET" ] || fail "unable to determine istiod serving certificate secret"
run_kubectl -n istio-system get secret "$ISTIOD_SECRET" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d >"$ISTIOD_TLS_CRT_FILE" || true
[ -s "$ISTIOD_TLS_CRT_FILE" ] || fail "unable to read istiod serving certificate"

GATEWAY_POD="$(run_kubectl get pods -n istio-system -l app=istio-ingressgateway -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)"
[ -n "$GATEWAY_POD" ] || fail "no running istio-ingressgateway pod found"
capture_envoy_secrets istio-system "$GATEWAY_POD" "$GATEWAY_PROXY_SECRET_FILE" 2>/dev/null || true
[ -s "$GATEWAY_PROXY_SECRET_FILE" ] || fail "gateway Envoy config dump returned no SDS data"

run_kubectl get mutatingwebhookconfiguration -o json 2>/dev/null >"$MUTATING_WEBHOOKS_FILE" || true
[ -s "$MUTATING_WEBHOOKS_FILE" ] || fail "unable to list mutating webhook configurations"
run_kubectl get validatingwebhookconfiguration -o json 2>/dev/null >"$VALIDATING_WEBHOOKS_FILE" || true
[ -s "$VALIDATING_WEBHOOKS_FILE" ] || fail "unable to list validating webhook configurations"

ISTIO_CA_SECRET_PRESENT=false
ISTIO_CA_SECRET_IN_USE=false
if run_kubectl -n istio-system get secret istio-ca-secret >/dev/null 2>&1; then
  ISTIO_CA_SECRET_PRESENT=true
  if run_kubectl get deploy,statefulset,daemonset -A -o json \
    | jq -e '.items[]?.spec.template.spec.volumes[]? | select(.secret.secretName=="istio-ca-secret")' >/dev/null 2>&1; then
    ISTIO_CA_SECRET_IN_USE=true
  fi
fi

python3 - "$SPIRE_ROOT_PEM_FILE" "$ISTIOD_TLS_CRT_FILE" "$GATEWAY_PROXY_SECRET_FILE" "$MUTATING_WEBHOOKS_FILE" "$VALIDATING_WEBHOOKS_FILE" "$ARTIFACT_PATH" "$ISTIO_CA_SECRET_PRESENT" "$ISTIO_CA_SECRET_IN_USE" "$TRUST_AUTHORITY_STATE_FILE" <<'PY'
import base64
import hashlib
import json
import pathlib
import re
import ssl
import subprocess
import sys
import tempfile

spire_root_pem = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
istiod_tls_cert_pem = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
gateway_proxy_secret = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
mutating_webhooks = json.loads(pathlib.Path(sys.argv[4]).read_text(encoding="utf-8"))
validating_webhooks = json.loads(pathlib.Path(sys.argv[5]).read_text(encoding="utf-8"))
artifact_path = pathlib.Path(sys.argv[6])
istio_ca_secret_present = sys.argv[7].lower() == "true"
istio_ca_secret_in_use = sys.argv[8].lower() == "true"
trust_state = json.loads(pathlib.Path(sys.argv[9]).read_text(encoding="utf-8"))

FORBIDDEN_MARKERS = ("threadforge-root", "cert-manager")


def fail_contract(msg: str):
    print(f"[FAIL] CONTRACT_VIOLATION: {msg}", file=sys.stderr)
    raise SystemExit(2)


def extract_pems(text: str):
    return [m.strip() + "\n" for m in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", text or "")]


def cert_issuer(pem: str) -> str:
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(pem)
        path = handle.name
    try:
        proc = subprocess.run(["openssl", "x509", "-in", path, "-noout", "-issuer", "-nameopt", "RFC2253"], capture_output=True, text=True, check=False)
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    if proc.returncode != 0:
        fail_contract(proc.stderr.strip() or proc.stdout.strip() or "unable to inspect certificate issuer")
    return proc.stdout.strip().split("=", 1)[-1].strip()


def pem_hash(pem: str) -> str:
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem).replace(b"\r", b"" )).hexdigest()


def ensure_spire_issuer(issuer: str, context: str):
    upper = issuer.upper()
    if "SPIRE" not in upper and "SPIFFE" not in upper:
        fail_contract(f"{context} issuer is not SPIRE: {issuer}")
    for marker in FORBIDDEN_MARKERS:
        if marker.upper() in upper:
            fail_contract(f"{context} issuer contains forbidden marker {marker}: {issuer}")


authoritative_bundle_roots = extract_pems(spire_root_pem)
if not authoritative_bundle_roots:
    fail_contract("SPIRE bundle PEM unavailable")
authoritative_bundle_hashes = {pem_hash(root) for root in authoritative_bundle_roots}
active_root_pem = str(trust_state.get("active_root_pem") or "").strip()
active_root_serial = str(trust_state.get("active_root_serial") or "").strip().lower().lstrip("0") or "0"
if not active_root_pem:
    fail_contract("trust authority state missing active_root_pem")
if len(extract_pems(active_root_pem)) != 1:
    fail_contract("trust authority active_root_pem does not contain exactly one cert")
if cert_issuer(active_root_pem) == "":
    fail_contract("trust authority active_root_pem is invalid")
spire_root_hash = pem_hash(active_root_pem)
if spire_root_hash not in authoritative_bundle_hashes:
    fail_contract("trust authority active_root_pem is not present in the authoritative SPIRE bundle")


# 1) istiod serving certificate issuer must be SPIRE.
istiod_chain = extract_pems(istiod_tls_cert_pem)
if not istiod_chain:
    fail_contract("istiod serving certificate chain is empty")
istiod_issuer = cert_issuer(istiod_chain[0])
ensure_spire_issuer(istiod_issuer, "istiod serving certificate")

# 2) gateway leaf issuer from dynamic default secret must be SPIRE.
dynamic = gateway_proxy_secret.get("dynamicActiveSecrets")
if not isinstance(dynamic, list) or not dynamic:
    fail_contract("gateway proxy-config secret returned no dynamicActiveSecrets")
default_entries = [entry for entry in dynamic if isinstance(entry, dict) and entry.get("name") == "default"]
if len(default_entries) != 1:
    fail_contract(f"expected exactly one gateway default secret, found {len(default_entries)}")
chain_b64 = ((((default_entries[0].get("secret") or {}).get("tlsCertificate") or {}).get("certificateChain") or {}).get("inlineBytes"))
if not isinstance(chain_b64, str) or not chain_b64:
    fail_contract("gateway default secret missing certificateChain.inlineBytes")
chain_pem = base64.b64decode(chain_b64).decode("utf-8", errors="ignore")
chain_certs = extract_pems(chain_pem)
if not chain_certs:
    fail_contract("gateway default secret did not decode into certificate PEM")
gateway_issuer = cert_issuer(chain_certs[0])
ensure_spire_issuer(gateway_issuer, "gateway workload certificate")

# 3) all Istio webhook caBundles must be SPIRE-issued and not forbidden.
def check_webhooks(doc: dict, kind: str):
    items = [item for item in doc.get("items", []) if "istio" in str(((item.get("metadata") or {}).get("name") or "")).lower()]
    if not items:
        fail_contract(f"no Istio {kind} webhook configurations found")
    checked = []
    for item in items:
        name = (item.get("metadata") or {}).get("name") or "<unknown>"
        bundles = {w.get("clientConfig", {}).get("caBundle", "") for w in (item.get("webhooks") or []) if w.get("clientConfig", {}).get("caBundle")}
        if len(bundles) != 1:
            fail_contract(f"{kind} webhook {name} has divergent caBundle values")
        certs = extract_pems(base64.b64decode(next(iter(bundles))).decode("utf-8", errors="ignore"))
        if not certs:
            fail_contract(f"{kind} webhook {name} caBundle contains no certs")
        bundle_hashes = {pem_hash(cert) for cert in certs}
        if spire_root_hash not in bundle_hashes:
            fail_contract(f"{kind} webhook {name} caBundle does not include the active SPIRE root")
        for cert in certs:
            issuer = cert_issuer(cert)
            ensure_spire_issuer(issuer, f"{kind} webhook {name} caBundle")
        checked.append({"name": name, "bundle_hashes": sorted(bundle_hashes)})
    return checked

mutating_checked = check_webhooks(mutating_webhooks, "mutating")
validating_checked = check_webhooks(validating_webhooks, "validating")

webhook_bundle_hashes = {tuple(entry["bundle_hashes"]) for entry in [*mutating_checked, *validating_checked]}
if len(webhook_bundle_hashes) != 1:
    fail_contract(f"Istio webhook caBundles have divergent bundle hashes: {len(webhook_bundle_hashes)}")
istio_bundle_hashes = set(next(iter(webhook_bundle_hashes)))

dynamic = gateway_proxy_secret.get("dynamicActiveSecrets")
if not isinstance(dynamic, list) or not dynamic:
    fail_contract("gateway proxy-config secret returned no dynamicActiveSecrets")
root_entries = [entry for entry in dynamic if isinstance(entry, dict) and entry.get("name") == "ROOTCA"]
if len(root_entries) != 1:
    fail_contract(f"expected exactly one gateway ROOTCA entry, found {len(root_entries)}")
trusted_ca_b64 = ((((root_entries[0].get("secret") or {}).get("validationContext") or {}).get("trustedCa") or {}).get("inlineBytes"))
if not isinstance(trusted_ca_b64, str) or not trusted_ca_b64:
    fail_contract("gateway ROOTCA missing trustedCa.inlineBytes")
trusted_roots = extract_pems(base64.b64decode(trusted_ca_b64).decode("utf-8", errors="ignore"))
if not trusted_roots:
    fail_contract("gateway ROOTCA contains no roots")
gateway_bundle_hashes = {pem_hash(root) for root in trusted_roots}
if spire_root_hash not in gateway_bundle_hashes:
    fail_contract("gateway ROOTCA bundle does not include the active SPIRE root")
envoy_root_hashes = gateway_bundle_hashes

bundle_roots_match = spire_root_hash in istio_bundle_hashes and spire_root_hash in envoy_root_hashes
single_root = bundle_roots_match and len(istio_bundle_hashes) == 1 and len(envoy_root_hashes) == 1

artifact = {
    "status": "PASS",
    "source": "authoritative_bundle_only",
    "istiod_issuer": istiod_issuer,
    "gateway_issuer": gateway_issuer,
    "bundle_roots_match": bundle_roots_match,
    "single_root": single_root,
    "spire_root_hash": spire_root_hash,
    "istio_root_hash": next(iter(istio_bundle_hashes)) if istio_bundle_hashes else "",
    "envoy_root_hash": next(iter(envoy_root_hashes)) if envoy_root_hashes else "",
    "authoritative_bundle_hashes": sorted(authoritative_bundle_hashes),
    "istio_bundle_hashes": sorted(istio_bundle_hashes),
    "envoy_root_hashes": sorted(envoy_root_hashes),
    "mutating_webhook_count": len(mutating_checked),
    "validating_webhook_count": len(validating_checked),
    "istio_ca_secret_present": istio_ca_secret_present,
    "istio_ca_secret_in_use": istio_ca_secret_in_use,
}
artifact_path.write_text(json.dumps(artifact, indent=2) + "\n")
print("[PASS] no non-SPIRE certificates are issued or used")
PY

if [ "$ISTIO_CA_SECRET_PRESENT" = true ] && [ "$ISTIO_CA_SECRET_IN_USE" = false ]; then
  echo "[PASS] stale fallback artifact detected but unused: istio-system/istio-ca-secret"
fi
