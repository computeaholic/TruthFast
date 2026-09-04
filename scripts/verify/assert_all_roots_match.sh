#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_ROOT="${REPO_ROOT}/artifacts/trust/root.pem"
KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"
ALL_ROOTS_MATCH_RETRIES="${ALL_ROOTS_MATCH_RETRIES:-20}"
ALL_ROOTS_MATCH_RETRY_INTERVAL_SECONDS="${ALL_ROOTS_MATCH_RETRY_INTERVAL_SECONDS:-2}"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
# shellcheck source=scripts/lib/envoy_admin.sh
source "$REPO_ROOT/scripts/lib/envoy_admin.sh"

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

read_istiod_tls_cert_with_retry() {
    local attempt cert
    for attempt in $(seq 1 "$ALL_ROOTS_MATCH_RETRIES"); do
        cert="$($KUBECTL_BIN get secret istiod-tls -n istio-system -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || true)"
        if [ -n "$cert" ]; then
            printf '%s' "$cert"
            return 0
        fi
        if (( attempt < ALL_ROOTS_MATCH_RETRIES )); then
            sleep "$ALL_ROOTS_MATCH_RETRY_INTERVAL_SECONDS"
        fi
    done
    return 1
}

[ -n "$KUBECTL_BIN" ] || fail "kubectl not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

SPIRE_SERVER_POD="$(select_active_spire_server_pod spire-system || true)"
[ -n "$SPIRE_SERVER_POD" ] || fail "unable to resolve SPIRE server pod"
SPIRE_BUNDLE_PEM="$($KUBECTL_BIN exec -n spire-system -c spire-server "$SPIRE_SERVER_POD" -- /opt/spire/bin/spire-server bundle show -socketPath /run/spire/private/spire-server.sock -format pem 2>/dev/null || true)"
[ -n "$SPIRE_BUNDLE_PEM" ] || fail "unable to read SPIRE bundle from ${SPIRE_SERVER_POD}"

SPIRE_CM_ROOT="$($KUBECTL_BIN get configmap spire-ca-root-cert -n spire-system -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null || true)"
[ -n "$SPIRE_CM_ROOT" ] || fail "spire-ca-root-cert missing root-cert.pem in spire-system"

ISTIO_CM_ROOT="$($KUBECTL_BIN get configmap istio-ca-root-cert -n istio-system -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null || true)"
[ -n "$ISTIO_CM_ROOT" ] || fail "istio-ca-root-cert missing root-cert.pem in istio-system"

$KUBECTL_BIN get pods -n istio-system -l app=istio-ingressgateway >/dev/null 2>&1 || fail "istio ingressgateway pods unavailable"
GATEWAY_POD="$($KUBECTL_BIN get pods -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$GATEWAY_POD" ] || fail "unable to resolve running istio-ingressgateway pod"

PROXY_SECRET_FILE="$(mktemp)"
trap 'rm -f "$PROXY_SECRET_FILE"' EXIT
capture_envoy_secrets istio-system "$GATEWAY_POD" "$PROXY_SECRET_FILE" 2>/dev/null || true
[ -s "$PROXY_SECRET_FILE" ] || fail "unable to read gateway Envoy SDS config"
PROXY_SECRET_JSON="$(cat "$PROXY_SECRET_FILE")"

ENVOY_CERTS_JSON="$($KUBECTL_BIN exec -n istio-system "$GATEWAY_POD" -c istio-proxy -- curl -s localhost:15000/certs 2>/dev/null || true)"
[ -n "$ENVOY_CERTS_JSON" ] || fail "unable to read gateway Envoy /certs"

ISTIOD_TLS_CERT="$(read_istiod_tls_cert_with_retry || true)"
[ -n "$ISTIOD_TLS_CERT" ] || fail "unable to read istiod-tls/tls.crt after ${ALL_ROOTS_MATCH_RETRIES} attempts"

MUTATING_WEBHOOK_JSON="$($KUBECTL_BIN get mutatingwebhookconfiguration istio-sidecar-injector -o json 2>/dev/null || true)"
[ -n "$MUTATING_WEBHOOK_JSON" ] || fail "unable to read mutating webhook config istio-sidecar-injector"

VALIDATING_WEBHOOKS_JSON="$($KUBECTL_BIN get validatingwebhookconfiguration istio-validator-istio-system istiod-default-validator -o json 2>/dev/null || true)"
[ -n "$VALIDATING_WEBHOOKS_JSON" ] || fail "unable to read validating webhook configs"

SPIRE_CSR_SECRET_JSON="$($KUBECTL_BIN get secret spire-csr-ca -n istio-system -o json 2>/dev/null || true)"
[ -n "$SPIRE_CSR_SECRET_JSON" ] || fail "unable to read secret istio-system/spire-csr-ca"

python3 - "$SPIRE_BUNDLE_PEM" "$SPIRE_CM_ROOT" "$ISTIO_CM_ROOT" "$PROXY_SECRET_JSON" "$ENVOY_CERTS_JSON" "$ISTIOD_TLS_CERT" "$MUTATING_WEBHOOK_JSON" "$VALIDATING_WEBHOOKS_JSON" "$SPIRE_CSR_SECRET_JSON" "$ARTIFACT_ROOT" <<'PY'
import base64
import hashlib
import json
import pathlib
import re
import ssl
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

spire_bundle, spire_cm_root, istio_cm_root, proxy_secret_json, envoy_certs_json, istiod_tls_cert, mutating_webhook_json, validating_webhooks_json, spire_csr_secret_json, artifact_root_path = sys.argv[1:]


def fail(msg: str) -> None:
    print(f"[FAIL] CONTRACT_VIOLATION: {msg}")
    raise SystemExit(2)


def extract_pems(text: str):
    return [m.strip() + "\n" for m in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", text or "")]


def fp(pem: str) -> str:
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem).replace(b"\r", b"")) .hexdigest()


def serial(pem: str) -> str:
    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        f.write(pem)
        path = f.name
    try:
        proc = subprocess.run(["openssl", "x509", "-in", path, "-noout", "-serial"], text=True, capture_output=True, check=False)
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    if proc.returncode != 0 or "=" not in proc.stdout:
        fail("unable to parse certificate serial")
    value = proc.stdout.split("=", 1)[1].strip().lower()
    return value.lstrip("0") or "0"


def normalize_serial(value: str) -> str:
    v = (value or "").strip().lower()
    if v.startswith("serial="):
        v = v.split("=", 1)[1]
    v = re.sub(r"^0+", "", v)
    return v or "0"


def subject(pem: str) -> str:
    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        f.write(pem)
        path = f.name
    try:
        proc = subprocess.run(["openssl", "x509", "-in", path, "-noout", "-subject", "-nameopt", "RFC2253"], text=True, capture_output=True, check=False)
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    if proc.returncode != 0:
        fail("unable to parse certificate subject")
    return proc.stdout.strip().split("subject=", 1)[-1].strip()


def issuer(pem: str) -> str:
    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        f.write(pem)
        path = f.name
    try:
        proc = subprocess.run(["openssl", "x509", "-in", path, "-noout", "-issuer", "-nameopt", "RFC2253"], text=True, capture_output=True, check=False)
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    if proc.returncode != 0:
        fail("unable to parse certificate issuer")
    return proc.stdout.strip().split("issuer=", 1)[-1].strip()


def validity_window(pem: str):
    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        f.write(pem)
        path = f.name
    try:
        proc = subprocess.run(["openssl", "x509", "-in", path, "-noout", "-startdate", "-enddate"], text=True, capture_output=True, check=False)
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    if proc.returncode != 0:
        fail("unable to parse certificate validity")
    fields = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            fields[k.strip()] = v.strip()
    try:
        not_before = datetime.strptime(fields["notBefore"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
        not_after = datetime.strptime(fields["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    except Exception:
        fail("failed to parse certificate validity window")
    return not_before, not_after


def cert_fields_from_pem(pem: str):
    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        f.write(pem if pem.endswith("\n") else pem + "\n")
        path = f.name
    try:
        proc = subprocess.run(
            ["openssl", "x509", "-in", path, "-noout", "-serial", "-subject", "-issuer", "-text"],
            text=True,
            capture_output=True,
            check=False,
        )
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    if proc.returncode != 0:
        return None
    fields = {"serial": "", "subject": "", "issuer": "", "is_ca": False, "self_signed": False}
    for line in proc.stdout.splitlines():
        s = line.strip()
        if s.startswith("serial="):
            fields["serial"] = normalize_serial(s.split("=", 1)[1])
        elif s.startswith("subject="):
            fields["subject"] = s.split("=", 1)[1].strip()
        elif s.startswith("issuer="):
            fields["issuer"] = s.split("=", 1)[1].strip()
        elif "CA:TRUE" in s:
            fields["is_ca"] = True
    fields["self_signed"] = fields["subject"] == fields["issuer"] and bool(fields["subject"])
    if not fields["serial"]:
        return None
    fields["fingerprint"] = fp(pem)
    return fields


try:
    spire_csr_secret_doc = json.loads(spire_csr_secret_json)
except Exception:
    fail("unable to parse secret istio-system/spire-csr-ca")

bundle_roots = extract_pems(spire_bundle)
if not bundle_roots:
    fail("SPIRE bundle contains no roots")

artifact_root = pathlib.Path(artifact_root_path)
if not artifact_root.exists():
    fail("trust root artifact missing")
active_root = artifact_root.read_text(encoding="utf-8").strip()
if not active_root:
    fail("trust root artifact empty")
active_root_pem = active_root
active_fp = fp(active_root)
active_serial = serial(active_root)
valid_bundle_fps = {fp(root) for root in bundle_roots if fp(root)}

serial_index = {}
subject_index = {}
cert_pems = list(bundle_roots)
for key in ("ca.crt", "tls.crt"):
    value = ((spire_csr_secret_doc.get("data") or {}).get(key) or "").strip()
    if not value:
        continue
    try:
        decoded = base64.b64decode(value).decode("utf-8", errors="ignore")
    except Exception:
        continue
    cert_pems.extend(extract_pems(decoded))

for pem in cert_pems:
    cert = cert_fields_from_pem(pem)
    if not cert:
        continue
    serial_index[cert["serial"]] = cert
    subject_index.setdefault(cert["subject"], []).append(cert)

if not serial_index:
    fail("unable to build lineage serial index from SPIRE bundle and spire-csr-ca")


def anchor_for_serial(cert_serial: str) -> str:
    current = serial_index.get(cert_serial)
    if not current:
        return ""
    seen = set()
    while current:
        current_serial = str(current.get("serial", ""))
        if not current_serial or current_serial in seen:
            return ""
        seen.add(current_serial)
        if current.get("self_signed"):
            return current_serial
        issuer_dn = str(current.get("issuer", ""))
        if not issuer_dn:
            return ""
        matches = subject_index.get(issuer_dn, [])
        if not matches:
            return ""
        current = matches[0]
    return ""


allowed_lineage_serials = set()
for cert_serial, cert in serial_index.items():
    anchor = anchor_for_serial(cert_serial)
    if anchor == active_serial and (bool(cert.get("is_ca")) or bool(cert.get("self_signed"))):
        allowed_lineage_serials.add(cert_serial)

if not allowed_lineage_serials:
    fail("allowed SPIRE-root lineage serial set is empty")

allowed_lineage_fps = {
    serial_index[s]["fingerprint"]
    for s in allowed_lineage_serials
    if s in serial_index and serial_index[s].get("fingerprint")
}

issuance_root_fp = ""
ca_value = ((spire_csr_secret_doc.get("data") or {}).get("ca.crt") or "").strip()
if ca_value:
    try:
        ca_pems = extract_pems(base64.b64decode(ca_value).decode("utf-8", errors="ignore"))
    except Exception:
        ca_pems = []
    if len(ca_pems) == 1:
        issuance_anchor = anchor_for_serial(serial(ca_pems[0]))
        if issuance_anchor and issuance_anchor in serial_index:
            issuance_root_fp = serial_index[issuance_anchor].get("fingerprint", "")

issuance_root_subject = ""
if issuance_root_fp:
    for cert in serial_index.values():
        if cert.get("fingerprint") == issuance_root_fp:
            issuance_root_subject = str(cert.get("subject", "")).strip()
            break

accepted_lineage_root_subjects = set()
accepted_lineage_root_serials = set()
for root in bundle_roots:
    root_fp = fp(root)
    if root_fp in valid_bundle_fps or (issuance_root_fp and root_fp == issuance_root_fp) or root_fp in allowed_lineage_fps:
        accepted_lineage_root_subjects.add(subject(root))
        accepted_lineage_root_serials.add(serial(root))


def published_root_accepted(root_pem: str, label: str) -> None:
    root_fp = fp(root_pem)
    if root_fp in valid_bundle_fps:
        return
    if issuance_root_fp and root_fp == issuance_root_fp:
        return
    if root_fp in allowed_lineage_fps:
        return
    fail(f"{label} does not match accepted SPIRE lineage roots")

spire_cm_roots = extract_pems(spire_cm_root)
istio_cm_roots = extract_pems(istio_cm_root)
spire_cm_hashes = {fp(root) for root in spire_cm_roots}
istio_cm_hashes = {fp(root) for root in istio_cm_roots}
if spire_cm_hashes != {active_fp}:
    fail(f"spire-ca-root-cert root set mismatch (expected 1, got {len(spire_cm_hashes)})")
if istio_cm_hashes != {active_fp}:
    fail(f"istio-ca-root-cert root set mismatch (expected 1, got {len(istio_cm_hashes)})")

for cert in spire_cm_roots:
    published_root_accepted(cert, "spire-ca-root-cert")
for cert in istio_cm_roots:
    published_root_accepted(cert, "istio-ca-root-cert")

proxy_doc = json.loads(proxy_secret_json)
root_entries = [e for e in (proxy_doc.get("dynamicActiveSecrets") or []) if e.get("name") == "ROOTCA"]
if len(root_entries) != 1:
    fail(f"expected exactly one gateway ROOTCA, found {len(root_entries)}")
trusted_ca_b64 = ((((root_entries[0].get("secret") or {}).get("validationContext") or {}).get("trustedCa") or {}).get("inlineBytes"))
if not trusted_ca_b64:
    fail("gateway ROOTCA missing trustedCa.inlineBytes")
gateway_root_pems = extract_pems(base64.b64decode(trusted_ca_b64).decode("utf-8", errors="ignore"))
if not gateway_root_pems:
    fail("gateway ROOTCA contains no roots")
gateway_root_hashes = {fp(root) for root in gateway_root_pems}
if fp(active_root) not in gateway_root_hashes:
    fail("gateway ROOTCA does not contain the active SPIRE root")

active_subject = subject(active_root)
active_issuer = issuer(active_root)
if "O=SPIRE" not in active_subject and "O=SPIFFE" not in active_subject:
    fail("active SPIRE root subject does not identify SPIRE/SPIFFE")

istiod_chain = extract_pems(istiod_tls_cert)
if not istiod_chain:
    fail("istiod-tls/tls.crt contains no certificate")
istiod_leaf = istiod_chain[0]
istiod_issuer_subject = issuer(istiod_leaf)
if "O=SPIRE" not in istiod_issuer_subject and "O=SPIFFE" not in istiod_issuer_subject:
    fail("istiod serving cert issuer is not SPIRE/SPIFFE")
if (
    (issuance_root_subject and istiod_issuer_subject != issuance_root_subject)
    and istiod_issuer_subject not in accepted_lineage_root_subjects
):
    fail("istiod serving cert issuer does not match issuance/accepted SPIRE lineage root subject")

mutating_doc = json.loads(mutating_webhook_json)
mutating_cas = {w.get("clientConfig", {}).get("caBundle", "") for w in mutating_doc.get("webhooks", []) if w.get("clientConfig", {}).get("caBundle")}
if len(mutating_cas) != 1:
    fail(f"mutating webhook caBundle count mismatch (expected 1, got {len(mutating_cas)})")
mutating_ca_pems = extract_pems(base64.b64decode(next(iter(mutating_cas))).decode("utf-8", errors="ignore"))
mutating_ca_hashes = {fp(root) for root in mutating_ca_pems}
if mutating_ca_hashes != {active_fp}:
    fail(f"mutating webhook caBundle root set mismatch (expected 1, got {len(mutating_ca_hashes)})")
for cert in mutating_ca_pems:
    published_root_accepted(cert, "mutating webhook caBundle")

validating_doc = json.loads(validating_webhooks_json)
for vcfg in validating_doc.get("items", []):
    ca_values = {w.get("clientConfig", {}).get("caBundle", "") for w in vcfg.get("webhooks", []) if w.get("clientConfig", {}).get("caBundle")}
    if len(ca_values) != 1:
        fail(f"validating webhook {vcfg.get('metadata', {}).get('name', '<unknown>')} caBundle count mismatch")
    ca_pems = extract_pems(base64.b64decode(next(iter(ca_values))).decode("utf-8", errors="ignore"))
    ca_hashes = {fp(root) for root in ca_pems}
    if ca_hashes != {active_fp}:
        fail(
            f"validating webhook {vcfg.get('metadata', {}).get('name', '<unknown>')} caBundle root set mismatch "
            f"(expected 1, got {len(ca_hashes)})"
        )
    for cert in ca_pems:
        published_root_accepted(cert, f"validating webhook {vcfg.get('metadata', {}).get('name', '<unknown>')} caBundle")

envoy_doc = json.loads(envoy_certs_json)
envoy_serials = set()
for cert in (envoy_doc.get("certificates") or []):
    for ca in (cert.get("ca_cert") or []):
        s = str(ca.get("serial_number", "")).strip().lower().lstrip("0")
        if s:
            envoy_serials.add(s)
if envoy_serials and not envoy_serials.issubset(accepted_lineage_root_serials):
    fail(
        f"Envoy /certs root serial mismatch (expected subset of {sorted(accepted_lineage_root_serials)}, got {sorted(envoy_serials)})"
    )

artifact_path = pathlib.Path(artifact_root_path)
artifact_path.parent.mkdir(parents=True, exist_ok=True)
artifact_path.write_text(active_root)

print("[PASS] SPIRE root propagated to Istio")
print("[PASS] istiod serving cert chains to SPIRE root")
print("[PASS] webhook caBundle matches SPIRE root")
print("[PASS] gateway ROOTCA matches SPIRE bundle")
print("all_roots_match=true")
PY
