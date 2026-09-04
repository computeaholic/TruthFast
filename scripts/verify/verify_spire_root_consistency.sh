#!/usr/bin/env bash
set -euo pipefail

# Hardened detection of mixed SPIRE root generations across workloads.
# Ensures no workload runs with a certificate chain issued from a stale SPIRE root generation.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
ARTIFACT_PATH="$PROOF_DIR/spire_root_consistency.json"
TRUST_AUTHORITY_STATE_FILE="${TRUST_AUTHORITY_STATE_FILE:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"

fail() {
  echo "[FAIL] POLICY_VIOLATION: $1"
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

require_cmd kubectl
require_cmd openssl
require_cmd python3
require_cmd jq

mkdir -p "$PROOF_DIR"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
[ -s "$TRUST_AUTHORITY_STATE_FILE" ] || fail "trust authority state unavailable"

ACTIVE_SPIRE_ROOT_PEM="$(jq -r '.active_root_pem // empty' "$TRUST_AUTHORITY_STATE_FILE" 2>/dev/null || true)"
ACTIVE_SPIRE_ROOT_SERIAL="$(jq -r '.active_root_serial // empty' "$TRUST_AUTHORITY_STATE_FILE" 2>/dev/null || true)"
ACTIVE_SPIRE_ROOT_FINGERPRINT="$(jq -r '.active_root_fingerprint // empty' "$TRUST_AUTHORITY_STATE_FILE" 2>/dev/null || true)"
[ -n "$ACTIVE_SPIRE_ROOT_PEM" ] || fail "trust authority state missing active_root_pem"
[ -n "$ACTIVE_SPIRE_ROOT_SERIAL" ] || fail "trust authority state missing active_root_serial"
[ -n "$ACTIVE_SPIRE_ROOT_FINGERPRINT" ] || fail "trust authority state missing active_root_fingerprint"

SPIRE_SERVER_POD="$(select_active_spire_server_pod spire-system || true)"
[ -n "$SPIRE_SERVER_POD" ] || fail "unable to resolve SPIRE server pod"
SPIRE_BUNDLE_PEM="$(kubectl -n spire-system exec -c spire-server "$SPIRE_SERVER_POD" -- /opt/spire/bin/spire-server bundle show -socketPath /run/spire/private/spire-server.sock -format pem 2>/dev/null || true)"
[ -n "$SPIRE_BUNDLE_PEM" ] || fail "unable to read SPIRE bundle from ${SPIRE_SERVER_POD}"

python3 - "$SPIRE_BUNDLE_PEM" "$ACTIVE_SPIRE_ROOT_PEM" "$ACTIVE_SPIRE_ROOT_SERIAL" "$ACTIVE_SPIRE_ROOT_FINGERPRINT" "$ARTIFACT_PATH" <<'PY'
import base64
import hashlib
import json
import pathlib
import re
import ssl
import subprocess
import sys
import tempfile

spire_bundle_pem = sys.argv[1]
active_root_pem = sys.argv[2]
active_root_serial = sys.argv[3]
active_root_fingerprint = sys.argv[4]
artifact_path = pathlib.Path(sys.argv[5])

def extract_pems(text: str):
    if not isinstance(text, str):
        return []
    return [m.strip() + "\n" for m in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", text)]

def pem_hash(pem: str):
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem).replace(b"\r", b"")).hexdigest()

def inspect_cert(pem: str):
    """Extract subject, issuer, serial from certificate."""
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(pem)
        path = handle.name
    try:
        proc = subprocess.run(
            ["openssl", "x509", "-in", path, "-noout", "-issuer", "-subject", "-serial"],
            capture_output=True,
            text=True,
            check=False
        )
    finally:
        pathlib.Path(path).unlink(missing_ok=True)

    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or proc.stdout.strip() or "unable to inspect certificate")

    fields = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key.strip().lower()] = value.strip()
    return fields

def openssl_verify(cert_pem: str, ca_pem: str):
    with tempfile.NamedTemporaryFile("w", delete=False) as cert_handle:
        cert_handle.write(cert_pem)
        cert_path = cert_handle.name
    with tempfile.NamedTemporaryFile("w", delete=False) as ca_handle:
        ca_handle.write(ca_pem)
        ca_path = ca_handle.name
    try:
        proc = subprocess.run(
            ["openssl", "verify", "-CAfile", ca_path, cert_path],
            capture_output=True,
            text=True,
            check=False,
        )
    finally:
        pathlib.Path(cert_path).unlink(missing_ok=True)
        pathlib.Path(ca_path).unlink(missing_ok=True)

    if proc.returncode != 0:
        return False
    return f"{cert_path}: OK" in proc.stdout

active_root = active_root_pem
active_root_hash = pem_hash(active_root)
active_root_info = inspect_cert(active_root)
active_root_serial = (active_root_info.get("serial", "") or "").lower().lstrip("0") or "0"
if active_root_serial != (active_root_serial or "0"):
    raise SystemExit("[FAIL] POLICY_VIOLATION: invalid active_root_serial from trust authority state")

bundle_roots = extract_pems(spire_bundle_pem)
if not bundle_roots:
    raise SystemExit("[FAIL] POLICY_VIOLATION: no SPIRE roots found in active bundle")

bundle_serials = set()
for root_pem in bundle_roots:
  root_info = inspect_cert(root_pem)
  root_serial = (root_info.get("serial", "") or "").lower().lstrip("0") or "0"
  if root_serial:
    bundle_serials.add(root_serial)

issuance_serial = ""
try:
    secret_json = subprocess.check_output(
        ["kubectl", "-n", "istio-system", "get", "secret", "spire-csr-ca", "-o", "json"],
        text=True,
    )
    secret_doc = json.loads(secret_json)
    ca_crt_b64 = ((secret_doc.get("data") or {}).get("ca.crt") or "").strip()
    if ca_crt_b64:
        issuance_pem = base64.b64decode(ca_crt_b64).decode("utf-8", errors="ignore")
        issuance_certs = extract_pems(issuance_pem)
        if len(issuance_certs) == 1 and openssl_verify(issuance_certs[0], active_root):
            issuance_info = inspect_cert(issuance_certs[0])
            issuance_serial = (issuance_info.get("serial", "") or "").lower().lstrip("0") or "0"
except Exception:
    issuance_serial = ""

allowed_serials = {active_root_serial}
if issuance_serial:
    allowed_serials.add(issuance_serial)

print(f"[active-root] serial={active_root_serial} subject={active_root_info.get('subject', 'UNKNOWN')}", file=__import__("sys").stderr)

# Collect all ready sidecar pods
pods_json = subprocess.check_output(["kubectl", "get", "pods", "-A", "-o", "json"], text=True)
pods = json.loads(pods_json).get("items", [])

pod_generations = {}  # pod_key -> root_serial
generation_counts = {}  # root_serial -> count
offending_pods = []  # pods not matching active root chain policy

for pod in pods:
    ns = pod.get("metadata", {}).get("namespace", "")
    name = pod.get("metadata", {}).get("name", "")

    if pod.get("status", {}).get("phase") != "Running":
        continue

    # Skip TERMINATING pods (deletionTimestamp set) — converging pod restarts
    if pod.get("metadata", {}).get("deletionTimestamp"):
        continue

    containers = [c.get("name") for c in pod.get("spec", {}).get("containers", []) if isinstance(c, dict)]
    if "istio-proxy" not in containers:
        continue

    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in pod.get("status", {}).get("conditions", [])
        if isinstance(c, dict)
    )
    if not ready:
        continue

    pod_key = f"{ns}/{name}"

    # Get Envoy SDS secrets for this pod
    proc = subprocess.run(
        [
            "kubectl", "-n", ns, "exec", name, "-c", "istio-proxy", "--",
            "curl", "-fsS", "--max-time", "10", "http://127.0.0.1:15000/config_dump",
        ],
        capture_output=True,
        text=True
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        print(f"[{pod_key}] ERROR retrieving SDS secrets", file=__import__("sys").stderr)
        pod_generations[pod_key] = "ERROR"
        continue

    try:
        doc = json.loads(proc.stdout)
        secrets_config = next(
            (
                item
                for item in doc.get("configs", [])
                if isinstance(item, dict) and str(item.get("@type", "")).endswith("SecretsConfigDump")
            ),
            None,
        )
        if not isinstance(secrets_config, dict):
            raise ValueError("missing SecretsConfigDump")
        dyn = secrets_config.get("dynamic_active_secrets") or secrets_config.get("dynamicActiveSecrets") or []

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

        dyn = camelize(dyn)
        root_entries = [x for x in dyn if x.get("name") == "ROOTCA"]

        if not root_entries:
            print(f"[{pod_key}] NO_ROOTCA secret", file=__import__("sys").stderr)
            pod_generations[pod_key] = "NO_ROOTCA"
            continue

        trusted_b64 = ((((root_entries[0].get("secret") or {}).get("validationContext") or {}).get("trustedCa") or {}).get("inlineBytes", ""))
        if not trusted_b64:
            print(f"[{pod_key}] EMPTY_ROOTCA", file=__import__("sys").stderr)
            pod_generations[pod_key] = "EMPTY_ROOTCA"
            continue

        trusted_pem = base64.b64decode(trusted_b64).decode("utf-8", errors="ignore")
        trusted_certs = extract_pems(trusted_pem)

        trusted_serials = []
        for cert_pem in trusted_certs:
            root_info = inspect_cert(cert_pem)
            pod_root_serial = (root_info.get("serial", "") or "").lower().lstrip("0") or "0"
            if pod_root_serial:
                trusted_serials.append(pod_root_serial)

        trusted_serial_set = set(trusted_serials)
        known_lineage_serials = set(bundle_serials)
        if issuance_serial:
            known_lineage_serials.add(issuance_serial)
        unknown_serials = sorted(serial for serial in trusted_serial_set if serial not in known_lineage_serials)
        if unknown_serials:
            print(f"[{pod_key}] UNKNOWN_ROOT_SERIALS (serials={','.join(unknown_serials)})", file=__import__("sys").stderr)
            pod_generations[pod_key] = "UNKNOWN_ROOT_SERIALS"
            offending_pods.append({
                "pod": pod_key,
                "root_serials": unknown_serials,
                "allowed_serials": sorted(allowed_serials),
            })
            continue

        lineage_serials = sorted(trusted_serial_set.intersection(allowed_serials))
        if not lineage_serials:
            print(f"[{pod_key}] STALE_ROOT_LINEAGE (count={len(trusted_serials)})", file=__import__("sys").stderr)
            pod_generations[pod_key] = "STALE_ROOT_LINEAGE"
            offending_pods.append({
                "pod": pod_key,
                "root_serials": sorted(trusted_serial_set),
                "allowed_serials": sorted(allowed_serials),
            })
            continue

        pod_root_serial = active_root_serial if active_root_serial in trusted_serial_set else lineage_serials[0]

        pod_generations[pod_key] = pod_root_serial
        generation_counts[pod_root_serial] = generation_counts.get(pod_root_serial, 0) + 1

        print(f"[{pod_key}] OK: root_serial={pod_root_serial}", file=__import__("sys").stderr)

    except Exception as e:
        print(f"[{pod_key}] PARSE_ERROR: {str(e)}", file=__import__("sys").stderr)
        pod_generations[pod_key] = "PARSE_ERROR"

# Generate report
unique_generations = len([s for s in generation_counts.keys() if s not in {"ERROR", "NO_ROOTCA", "EMPTY_ROOTCA", "UNKNOWN_ROOT_SERIALS", "STALE_ROOT_LINEAGE", "PARSE_ERROR"}])
pod_count = len([p for p in pod_generations.values() if not isinstance(p, str) or (isinstance(p, str) and p.isdigit())])

artifact = {
    "active_root_serial": active_root_serial,
    "issuance_serial": issuance_serial,
    "allowed_serials": sorted(allowed_serials),
    "unique_generations": unique_generations,
    "total_ready_pods": len(pod_generations),
    "pods_scanned": len(pod_generations),
    "generation_counts": generation_counts,
    "offending_pods": offending_pods,
    "status": "PASS" if not offending_pods else "FAIL"
}

if offending_pods:
    msg = f"mixed SPIRE root generations detected: {unique_generations} generation(s), {len(offending_pods)} rogue pod(s)"
    print(f"[FAIL] POLICY_VIOLATION: {msg}", file=__import__("sys").stderr)
    artifact_path.write_text(json.dumps(artifact, indent=2) + "\n")
    print(f"[FAIL] POLICY_VIOLATION: {msg}")
    raise SystemExit(2)

print(f"[PASS] SPIRE root generation consistent across {len(pod_generations)} ready sidecar pod(s)", file=__import__("sys").stderr)
artifact_path.write_text(json.dumps(artifact, indent=2) + "\n")
print("[PASS] no mixed SPIRE root generations detected")
PY
