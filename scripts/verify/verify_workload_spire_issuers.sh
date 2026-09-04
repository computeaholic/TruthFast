#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/artifacts/identity"
SUMMARY_PATH="$ARTIFACT_DIR/workload_spire_issuer_validation.json"
PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
PROOF_SUMMARY_PATH="$PROOF_DIR/workload_spire_issuer_validation.json"
TRUST_AUTHORITY_STATE_FILE="${TRUST_AUTHORITY_STATE_FILE:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"

KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"
OPENSSL_BIN="${OPENSSL_BIN:-$(type -P openssl || true)}"

fail() {
  echo "[FAIL] IDENTITY_CHAIN_VIOLATION: $1"
  exit 2
}

[ -n "$KUBECTL_BIN" ] || fail "kubectl not found"
[ -n "$OPENSSL_BIN" ] || fail "openssl not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

mkdir -p "$ARTIFACT_DIR" "$PROOF_DIR"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
# shellcheck source=scripts/lib/envoy_admin.sh
source "$REPO_ROOT/scripts/lib/envoy_admin.sh"

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
[ -s "$TRUST_AUTHORITY_STATE_FILE" ] || fail "trust authority state unavailable"

SPIRE_SERVER_POD="$(select_active_spire_server_pod spire-system || true)"
[ -n "$SPIRE_SERVER_POD" ] || fail "unable to resolve SPIRE server pod"
SPIRE_BUNDLE_PEM="$("$KUBECTL_BIN" exec -n spire-system -c spire-server "$SPIRE_SERVER_POD" -- /opt/spire/bin/spire-server bundle show -socketPath /run/spire/private/spire-server.sock -format pem 2>/dev/null || true)"
[ -n "$SPIRE_BUNDLE_PEM" ] || fail "SPIRE bundle PEM unavailable"

python3 - "$SPIRE_BUNDLE_PEM" "$SUMMARY_PATH" "$PROOF_SUMMARY_PATH" "$KUBECTL_BIN" "$OPENSSL_BIN" "$TRUST_AUTHORITY_STATE_FILE" <<'PY'
from __future__ import annotations

import base64
import json
import pathlib
import re
import subprocess
import sys
import tempfile


def fail(msg: str) -> None:
    print(f"[FAIL] IDENTITY_CHAIN_VIOLATION: {msg}")
    raise SystemExit(2)


def run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        err = proc.stderr.strip() or proc.stdout.strip() or f"command failed: {' '.join(cmd)}"
        fail(err)
    return proc.stdout


def extract_pems(text: str) -> list[str]:
    return [m.strip() + "\n" for m in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", text or "")]


def cert_serial(pem: str, openssl_bin: str) -> str:
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(pem)
        path = handle.name
    try:
        proc = subprocess.run([openssl_bin, "x509", "-in", path, "-noout", "-serial"], capture_output=True, text=True, check=False)
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    if proc.returncode != 0:
        fail(proc.stderr.strip() or proc.stdout.strip() or "openssl x509 -serial failed")
    raw = proc.stdout.strip().split("=", 1)[-1].strip().lower().lstrip("0")
    return raw or "0"


def cert_issuer(pem: str, openssl_bin: str) -> str:
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(pem)
        path = handle.name
    try:
        proc = subprocess.run([openssl_bin, "x509", "-in", path, "-noout", "-issuer", "-nameopt", "RFC2253"], capture_output=True, text=True, check=False)
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    if proc.returncode != 0:
        fail(proc.stderr.strip() or proc.stdout.strip() or "openssl x509 -issuer failed")
    return proc.stdout.strip().split("=", 1)[-1].strip()


def cert_issuer(pem: str, openssl_bin: str) -> str:
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(pem)
        path = handle.name
    try:
        proc = subprocess.run([openssl_bin, "x509", "-in", path, "-noout", "-issuer", "-nameopt", "RFC2253"], capture_output=True, text=True, check=False)
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    if proc.returncode != 0:
        fail(proc.stderr.strip() or proc.stdout.strip() or "openssl x509 -issuer failed")
    return proc.stdout.strip().split("=", 1)[-1].strip()


spire_bundle_pem = sys.argv[1]
summary_path = pathlib.Path(sys.argv[2])
proof_summary_path = pathlib.Path(sys.argv[3])
kubectl_bin = sys.argv[4]
openssl_bin = sys.argv[5]
trust_state_path = pathlib.Path(sys.argv[6])

roots = extract_pems(spire_bundle_pem)
if not roots:
    fail("SPIRE bundle did not include any roots")
trust_state = json.loads(trust_state_path.read_text(encoding="utf-8"))
active_root_pem = str(trust_state.get("active_root_pem") or "").strip()
active_root_serial = str(trust_state.get("active_root_serial") or "").strip().lower().lstrip("0") or "0"
if not active_root_pem:
    fail("trust authority state missing active_root_pem")
if cert_serial(active_root_pem, openssl_bin) != active_root_serial:
    fail("trust authority active_root_pem does not match active_root_serial")

pods_doc = json.loads(
    run(
        [
            kubectl_bin,
            "get",
            "pods",
            "-A",
            "-o",
            "json",
        ]
    )
)

workloads = []
for item in pods_doc.get("items", []):
    meta = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})
    if meta.get("deletionTimestamp"):
        continue
    if status.get("phase") != "Running":
        continue
    conditions = status.get("conditions") or []
    ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions if isinstance(c, dict))
    if not ready:
        continue
    containers = [c.get("name") for c in (spec.get("containers") or []) if isinstance(c, dict)]
    if "istio-proxy" not in containers:
        continue
    workloads.append(
        {
            "namespace": meta.get("namespace", ""),
            "pod": meta.get("name", ""),
            "service_account": spec.get("serviceAccountName") or "default",
        }
    )

if not workloads:
    fail("no running istio-proxy workloads found")

results = []
for workload in workloads:
    ns = workload["namespace"]
    pod = workload["pod"]

    certs_raw = run([kubectl_bin, "exec", "-n", ns, pod, "-c", "istio-proxy", "--", "curl", "-s", "localhost:15000/certs"])
    certs_doc = json.loads(certs_raw)

    spiffe_ids: set[str] = set()
    ca_serials: set[str] = set()
    for cert in certs_doc.get("certificates", []) or []:
        if not isinstance(cert, dict):
            continue
        for leaf in cert.get("cert_chain") or []:
            if not isinstance(leaf, dict):
                continue
            for san in leaf.get("subject_alt_names") or []:
                if isinstance(san, dict) and isinstance(san.get("uri"), str) and san["uri"].startswith("spiffe://"):
                    spiffe_ids.add(san["uri"])
        for ca in cert.get("ca_cert") or []:
            if not isinstance(ca, dict):
                continue
            serial = str(ca.get("serial_number", "")).strip().lower().lstrip("0")
            if serial:
                ca_serials.add(serial)

    expected_spiffe = f"spiffe://identity.threadforge.local/ns/{ns}/sa/{workload['service_account']}"
    if expected_spiffe not in spiffe_ids:
        fail(f"{ns}/{pod} missing expected SPIFFE ID in /certs: {expected_spiffe}")
    if len(ca_serials) != 1:
        fail(f"{ns}/{pod} exposed non-deterministic CA serials in /certs: {sorted(ca_serials)}")
    runtime_ca_serial = next(iter(ca_serials))

    secret_path = pathlib.Path(tempfile.mktemp(prefix="envoy-secrets-"))
    try:
        subprocess.run(
            [
                kubectl_bin,
                "-n",
                ns,
                "exec",
                pod,
                "-c",
                "istio-proxy",
                "--",
                "curl",
                "-fsS",
                "--max-time",
                "10",
                "http://127.0.0.1:15000/config_dump",
            ],
            check=True,
            stdout=secret_path.open("w", encoding="utf-8"),
            text=True,
        )
        dump = json.loads(secret_path.read_text(encoding="utf-8"))
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        fail(f"{ns}/{pod} Envoy config dump unavailable: {exc}")
    finally:
        secret_path.unlink(missing_ok=True)
    configs = dump.get("configs") if isinstance(dump, dict) else None
    secrets_config = next(
        (
            item
            for item in configs or []
            if isinstance(item, dict) and str(item.get("@type", "")).endswith("SecretsConfigDump")
        ),
        None,
    )
    if not isinstance(secrets_config, dict):
        fail(f"{ns}/{pod} Envoy config dump has no SecretsConfigDump")
    dynamic_raw = secrets_config.get("dynamic_active_secrets")
    if dynamic_raw is None:
        dynamic_raw = secrets_config.get("dynamicActiveSecrets")
    static_raw = secrets_config.get("static_secrets")
    if static_raw is None:
        static_raw = secrets_config.get("staticSecrets")

    def camelize(value):
        if isinstance(value, dict):
            result = {}
            for key, item in value.items():
                head, *tail = str(key).split("_")
                result[head + "".join(part[:1].upper() + part[1:] for part in tail)] = camelize(item)
            return result
        if isinstance(value, list):
            return [camelize(item) for item in value]
        return value

    secret_doc = {"dynamicActiveSecrets": camelize(dynamic_raw or []), "staticSecrets": camelize(static_raw or [])}
    dynamic = secret_doc.get("dynamicActiveSecrets")
    if not isinstance(dynamic, list) or not dynamic:
        fail(f"{ns}/{pod} missing dynamicActiveSecrets")
    default_entries = [entry for entry in dynamic if isinstance(entry, dict) and entry.get("name") == "default"]
    if len(default_entries) != 1:
        fail(f"{ns}/{pod} expected one default secret, found {len(default_entries)}")

    cert_b64 = (((default_entries[0].get("secret") or {}).get("tlsCertificate") or {}).get("certificateChain") or {}).get("inlineBytes")
    if not isinstance(cert_b64, str) or not cert_b64:
        fail(f"{ns}/{pod} default secret missing certificateChain.inlineBytes")
    chain = extract_pems(base64.b64decode(cert_b64).decode("utf-8", errors="ignore"))
    if not chain:
        fail(f"{ns}/{pod} default secret did not decode into certificate PEM")

    issuer = cert_issuer(chain[0], openssl_bin)
    issuer_upper = issuer.upper()
    if "SPIRE" not in issuer_upper and "SPIFFE" not in issuer_upper:
        fail(f"{ns}/{pod} issuer is not SPIRE: {issuer}")
    if "THREADFORGE-ROOT" in issuer_upper or "CERT-MANAGER" in issuer_upper:
        fail(f"{ns}/{pod} issuer is forbidden: {issuer}")

    results.append(
        {
            "namespace": ns,
            "pod": pod,
            "spiffe_id": expected_spiffe,
            "issuer": issuer,
            "runtime_ca_serial": runtime_ca_serial,
            "status": "PASS",
        }
    )

artifact = {
    "status": "PASS",
    "active_spire_root_serial": active_root_serial,
    "workload_count": len(results),
    "workloads": results,
}

summary_path.write_text(json.dumps(artifact, indent=2) + "\n")
proof_summary_path.write_text(json.dumps(artifact, indent=2) + "\n")
print(f"[PASS] all {len(results)} workload certificates are SPIRE-issued via SDS")
PY
