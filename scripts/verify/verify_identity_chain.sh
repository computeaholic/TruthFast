#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/artifacts/identity"
SUMMARY_PATH="$ARTIFACT_DIR/identity_chain_validation.json"
SPIRE_BUNDLE_PATH="$ARTIFACT_DIR/spire_bundle.json"
PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
PROOF_SUMMARY_PATH="$PROOF_DIR/identity_chain_validation.json"
FAILURE_PATH="$REPO_ROOT/artifacts/debug/identity_chain_failure.log"
REAL_KUBECTL="${KUBECTL_BIN:-$(type -P kubectl || true)}"
OPENSSL_BIN="${OPENSSL_BIN:-$(type -P openssl || true)}"

# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
require_trust_domain

if [ -z "$REAL_KUBECTL" ] || [ -z "$OPENSSL_BIN" ]; then
  echo "[FAIL] IDENTITY_CHAIN_VIOLATION: kubectl and openssl are required"
  exit 2
fi

SPIRE_SERVER_POD="$(select_active_spire_server_pod spire-system || true)"
if [ -z "$SPIRE_SERVER_POD" ]; then
  echo "[FAIL] IDENTITY_CHAIN_VIOLATION: unable to select a ready spire-server pod"
  exit 2
fi
export SPIRE_SERVER_POD

mkdir -p "$ARTIFACT_DIR" "$PROOF_DIR" "$REPO_ROOT/artifacts/debug"

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
python3 - "$REPO_ROOT" "$ARTIFACT_DIR" "$SUMMARY_PATH" "$SPIRE_BUNDLE_PATH" "$PROOF_SUMMARY_PATH" "$FAILURE_PATH" "$REAL_KUBECTL" "$OPENSSL_BIN" "$SPIFFE_TRUST_DOMAIN" <<'PY'
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from identity_chain_roots import IdentityRootError, select_authorized_issuance_root


class IdentityChainViolation(RuntimeError):
    pass


repo_root = Path(sys.argv[1])
artifact_dir = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
spire_bundle_path = Path(sys.argv[4])
proof_summary_path = Path(sys.argv[5])
failure_path = Path(sys.argv[6])
kubectl_bin = sys.argv[7]
openssl_bin = sys.argv[8]
trust_domain = sys.argv[9]
recycle_timeout_seconds = int(os.getenv("IDENTITY_CHAIN_RECYCLE_TIMEOUT_SECONDS", "300"))
recycle_retry_interval_seconds = float(os.getenv("IDENTITY_CHAIN_RECYCLE_RETRY_INTERVAL_SECONDS", "2"))
identity_snapshot_timeout_seconds = float(os.getenv("IDENTITY_SNAPSHOT_TIMEOUT_SECONDS", "30"))
identity_snapshot_retry_interval_seconds = float(os.getenv("IDENTITY_SNAPSHOT_RETRY_INTERVAL_SECONDS", "1"))
proof_mode = os.getenv("VERIFY_EXECUTION_MODE") == "proof"

targets = [
    {
        "artifact_name": "echo",
        "workload": "echo",
        "namespace": "threadforge-test",
        "deployment": "echo",
        "deployment_ref": "deploy/echo",
    },
    {
        "artifact_name": "ingressgateway",
        "workload": "ingressgateway",
        "namespace": "istio-system",
        "deployment": "istio-ingressgateway",
        "deployment_ref": "deploy/istio-ingressgateway",
    },
]


def run(cmd: list[str], *, input_text: str | None = None, check: bool = True) -> str:
    proc = subprocess.run(
        cmd,
        input=input_text,
        text=True,
        capture_output=True,
        check=False,
    )
    if check and proc.returncode != 0:
        message = proc.stderr.strip() or proc.stdout.strip() or f"command failed: {' '.join(cmd)}"
        raise IdentityChainViolation(message)
    return proc.stdout


def extract_pems(text: str) -> list[str]:
    return [match.strip() + "\n" for match in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", text or "")]


def pem_sha256(pem: str) -> str:
    import ssl

    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem).replace(b"\r", b"")) .hexdigest()


def openssl_view(pem: str, *extra: str) -> str:
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(pem)
        temp_path = handle.name
    try:
        proc = subprocess.run(
            [openssl_bin, "x509", "-in", temp_path, "-noout", *extra],
            text=True,
            capture_output=True,
            check=False,
        )
    finally:
        Path(temp_path).unlink(missing_ok=True)
    if proc.returncode != 0:
        raise IdentityChainViolation(proc.stderr.strip() or proc.stdout.strip() or "openssl x509 failed")
    return proc.stdout


def inspect_cert(pem: str) -> dict[str, Any]:
    text = openssl_view(pem, "-subject", "-issuer", "-serial", "-fingerprint", "-sha256", "-ext", "subjectAltName")
    result: dict[str, Any] = {"sans": []}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("subject="):
            result["subject"] = line.split("=", 1)[1].strip()
        elif line.startswith("issuer="):
            result["issuer"] = line.split("=", 1)[1].strip()
        elif line.startswith("serial="):
            result["serial"] = normalize_serial(line.split("=", 1)[1].strip().lower())
        elif line.startswith("sha256 Fingerprint="):
            result["fingerprint"] = line.split("=", 1)[1].replace(":", "").lower()
        elif "URI:" in line:
            sans = []
            for part in line.split(","):
                part = part.strip()
                if part.startswith("URI:"):
                    sans.append(part.replace("URI:", "", 1).strip())
            result["sans"] = sans
    result.setdefault("subject", "")
    result.setdefault("issuer", "")
    result.setdefault("serial", "")
    result.setdefault("fingerprint", pem_sha256(pem))
    return result


def inspect_cert_validity(pem: str) -> tuple[dt.datetime, dt.datetime]:
    text = openssl_view(pem, "-startdate", "-enddate")
    fields: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key.strip()] = value.strip()
    try:
        not_before = dt.datetime.strptime(fields["notBefore"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
        not_after = dt.datetime.strptime(fields["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
    except Exception as exc:
        raise IdentityChainViolation(f"unable to parse certificate validity window: {exc}") from exc
    return not_before, not_after


def select_current_spire_root(spire_roots: list[str]) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
    if not spire_roots:
        raise IdentityChainViolation("SPIRE bundle did not contain any roots")

    now = dt.datetime.now(dt.timezone.utc)
    valid_roots: list[tuple[dt.datetime, str, dict[str, Any]]] = []
    described_roots: list[dict[str, Any]] = []

    for pem in spire_roots:
        info = inspect_cert(pem)
        not_before, not_after = inspect_cert_validity(pem)
        root_entry = {
            "subject": info["subject"],
            "issuer": info["issuer"],
            "serial": info["serial"],
            "fingerprint": info["fingerprint"],
            "not_before": not_before.isoformat(),
            "not_after": not_after.isoformat(),
            "pem": pem,
            "currently_valid": not_before <= now <= not_after,
        }
        described_roots.append(root_entry)
        if root_entry["currently_valid"]:
            valid_roots.append((not_before, pem, info))

    if not valid_roots:
        raise IdentityChainViolation("SPIRE bundle has no currently valid roots")

    current_roots = sorted(
        valid_roots,
        key=lambda item: (
            item[0],
            normalize_serial(item[2].get("serial", "")),
        ),
    )
    if not current_roots:
        raise IdentityChainViolation("SPIRE bundle did not contain a selectable active root")

    current_pem, current_info = current_roots[-1][1], current_roots[-1][2]
    return current_pem, current_info, described_roots


def normalize_serial(value: str) -> str:
    return re.sub(r"^0+", "", str(value or "").replace(":", "").lower()) or "0"


def openssl_verify(leaf_pem: str, root_pem: str, signer_pem: str | None = None) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        leaf_path = temp / "leaf.pem"
        root_path = temp / "root.pem"
        leaf_path.write_text(leaf_pem)
        root_path.write_text(root_pem)
        cmd = [openssl_bin, "verify", "-CAfile", str(root_path)]
        if signer_pem is not None:
            signer_path = temp / "signer.pem"
            signer_path.write_text(signer_pem)
            cmd.extend(["-untrusted", str(signer_path)])
        cmd.append(str(leaf_path))
        proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
        if proc.returncode != 0:
            raise IdentityChainViolation(proc.stderr.strip() or proc.stdout.strip() or "openssl verify failed")
        expected = f"{leaf_path}: OK"
        if expected not in proc.stdout:
            raise IdentityChainViolation(f"unexpected openssl verify output: {proc.stdout.strip()}")


def load_issuance_serial(kubectl: str, active_root_pem: str) -> str | None:
    secret_json = run([kubectl, "get", "secret", "-n", "istio-system", "spire-csr-ca", "-o", "json"], check=False)
    if not secret_json.strip():
        return None
    doc = load_json(secret_json, "secret istio-system/spire-csr-ca")
    ca_b64 = ((doc.get("data") or {}).get("ca.crt") or "").strip()
    if not ca_b64:
        return None
    try:
        ca_pem = base64.b64decode(ca_b64).decode("utf-8", errors="ignore")
    except Exception:
        return None
    certs = extract_pems(ca_pem)
    if len(certs) != 1:
        return None
    # Fail closed: only accept issuance serials that verify to the active SPIRE root.
    openssl_verify(certs[0], active_root_pem)
    info = inspect_cert(certs[0])
    return info["serial"]


def cert_fields_from_pem(pem: str) -> dict[str, Any] | None:
    text = openssl_view(pem, "-serial", "-subject", "-issuer", "-text")
    fields: dict[str, Any] = {
        "serial": "",
        "subject": "",
        "issuer": "",
        "is_ca": False,
        "self_signed": False,
    }
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("serial="):
            serial = line.split("=", 1)[1].strip().lower()
            fields["serial"] = re.sub(r"^0+", "", serial) or "0"
        elif line.startswith("subject="):
            fields["subject"] = line.split("=", 1)[1].strip()
        elif line.startswith("issuer="):
            fields["issuer"] = line.split("=", 1)[1].strip()
        elif "CA:TRUE" in line:
            fields["is_ca"] = True
    fields["self_signed"] = fields["subject"] == fields["issuer"] and bool(fields["subject"])
    if not fields["serial"]:
        return None
    return fields


def build_lineage_allowed_root_serials(active_root_serial: str, bundle_pem: str, secret_doc: dict[str, Any]) -> set[str]:
    serial_index: dict[str, dict[str, Any]] = {}
    subject_index: dict[str, list[dict[str, Any]]] = {}

    cert_pems: list[str] = []
    cert_pems.extend(extract_pems(bundle_pem))

    data = (secret_doc.get("data") or {}) if isinstance(secret_doc, dict) else {}
    for key in ("ca.crt", "tls.crt"):
        value = data.get(key)
        if not isinstance(value, str) or not value.strip():
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
        raise IdentityChainViolation("unable to build lineage serial index from SPIRE bundle and spire-csr-ca")

    def anchor_for_serial(serial: str) -> str:
        current = serial_index.get(serial)
        if not current:
            return ""
        seen: set[str] = set()
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

    allowed: set[str] = set()
    for serial, cert in serial_index.items():
        anchor = anchor_for_serial(serial)
        if anchor == active_root_serial and (bool(cert.get("is_ca")) or bool(cert.get("self_signed"))):
            allowed.add(serial)
    return allowed


def dedupe(items: list[str]) -> list[str]:
    return sorted({item for item in items if item})


def load_json(text: str, context: str) -> dict[str, Any]:
    try:
        obj = json.loads(text)
    except Exception as exc:
        raise IdentityChainViolation(f"invalid JSON from {context}: {exc}") from exc
    if not isinstance(obj, dict):
        raise IdentityChainViolation(f"unexpected JSON shape from {context}")
    return obj


def snake_to_camel(value: str) -> str:
    head, *tail = value.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in tail)


def camelize(value: Any) -> Any:
    if isinstance(value, dict):
        return {snake_to_camel(str(key)): camelize(item) for key, item in value.items()}
    if isinstance(value, list):
        return [camelize(item) for item in value]
    return value


def load_direct_envoy_config_dump(pod: str, namespace: str) -> tuple[dict[str, Any], dict[str, Any]]:
    dump = load_json(
        run(
            [
                kubectl_bin,
                "exec",
                "-n",
                namespace,
                pod,
                "-c",
                "istio-proxy",
                "--",
                "curl",
                "-fsS",
                "--max-time",
                "10",
                "http://127.0.0.1:15000/config_dump",
            ]
        ),
        f"Envoy config dump for {namespace}/{pod}",
    )
    configs = dump.get("configs")
    if not isinstance(configs, list):
        raise IdentityChainViolation("Envoy config dump returned no configs")
    bootstrap_config = next(
        (item for item in configs if isinstance(item, dict) and item.get("@type", "").endswith("BootstrapConfigDump")),
        None,
    )
    secrets_config = next(
        (item for item in configs if isinstance(item, dict) and item.get("@type", "").endswith("SecretsConfigDump")),
        None,
    )
    if not isinstance(bootstrap_config, dict) or not isinstance(secrets_config, dict):
        raise IdentityChainViolation("Envoy config dump missing bootstrap or secrets config")
    bootstrap = bootstrap_config.get("bootstrap")
    if not isinstance(bootstrap, dict):
        raise IdentityChainViolation("Envoy config dump missing bootstrap payload")
    secret_doc = {
        "dynamic_active_secrets": secrets_config.get("dynamic_active_secrets") or [],
        "static_secrets": secrets_config.get("static_secrets") or [],
    }
    return camelize(bootstrap), camelize(secret_doc)


def selector_arg(selector: dict[str, str]) -> str:
    return ",".join(f"{key}={value}" for key, value in sorted(selector.items()))


def resolve_running_pod(target: dict[str, str]) -> dict[str, str]:
    deploy = load_json(
        run([kubectl_bin, "-n", target["namespace"], "get", "deploy", target["deployment"], "-o", "json"]),
        f"deployment {target['namespace']}/{target['deployment']}",
    )
    selector = deploy.get("spec", {}).get("selector", {}).get("matchLabels", {})
    if not isinstance(selector, dict) or not selector:
        raise IdentityChainViolation(f"deployment {target['namespace']}/{target['deployment']} has no selector")
    pods = load_json(
        run(
            [
                kubectl_bin,
                "-n",
                target["namespace"],
                "get",
                "pods",
                "-l",
                selector_arg(selector),
                "-o",
                "json",
            ]
        ),
        f"pods for {target['namespace']}/{target['deployment']}",
    )
    for item in pods.get("items", []):
        if item.get("metadata", {}).get("deletionTimestamp"):
            continue
        if item.get("status", {}).get("phase") != "Running":
            continue
        conditions = item.get("status", {}).get("conditions") or []
        ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions if isinstance(c, dict))
        if not ready:
            continue
        containers = [c.get("name") for c in item.get("spec", {}).get("containers", []) if isinstance(c, dict)]
        if "istio-proxy" not in containers:
            continue
        return {
            "pod": item.get("metadata", {}).get("name", ""),
            "service_account": item.get("spec", {}).get("serviceAccountName") or "default",
        }
    raise IdentityChainViolation(f"no ready istio-proxy pod found for {target['namespace']}/{target['deployment']}")


def recursive_find_paths(node: Any) -> list[str]:
    paths: list[str] = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "path" and isinstance(value, str):
                paths.append(value)
            else:
                paths.extend(recursive_find_paths(value))
    elif isinstance(node, list):
        for item in node:
            paths.extend(recursive_find_paths(item))
    return paths


def find_sds_socket_path(bootstrap: dict[str, Any]) -> str:
    paths = [p for p in recursive_find_paths(bootstrap) if "workload-spiffe-uds" in p or "/socket" in p]
    unique = dedupe(paths)
    if not unique:
        raise IdentityChainViolation("no SDS workload socket path found in Envoy bootstrap")
    if len(unique) != 1:
        raise IdentityChainViolation(f"ambiguous SDS socket paths in Envoy bootstrap: {unique}")
    return unique[0]


def parse_admin_identity(admin_doc: dict[str, Any], expected_spiffe: str) -> dict[str, Any]:
    certificates = admin_doc.get("certificates")
    if not isinstance(certificates, list) or not certificates:
        raise IdentityChainViolation("Envoy /certs returned no certificates")
    matches = []
    for entry in certificates:
        if not isinstance(entry, dict):
            continue
        chain = entry.get("cert_chain") or []
        ca_chain = entry.get("ca_cert") or []
        leaf_uris = []
        leaf_serials = []
        for leaf in chain:
            if not isinstance(leaf, dict):
                continue
            serial = normalize_serial(str(leaf.get("serial_number", "")).strip().lower())
            if serial:
                leaf_serials.append(serial)
            for san in leaf.get("subject_alt_names") or []:
                uri = san.get("uri") if isinstance(san, dict) else None
                if isinstance(uri, str) and uri.startswith("spiffe://"):
                    leaf_uris.append(uri)
        if expected_spiffe not in leaf_uris:
            continue
        ca_serials = []
        for ca in ca_chain:
            if not isinstance(ca, dict):
                continue
            serial = normalize_serial(str(ca.get("serial_number", "")).strip().lower())
            if serial:
                ca_serials.append(serial)
        matches.append(
            {
                "spiffe_ids": dedupe(leaf_uris),
                "leaf_serials": dedupe(leaf_serials),
                "ca_serials": dedupe(ca_serials),
            }
        )
    if not matches:
        raise IdentityChainViolation(f"Envoy /certs did not expose expected SPIFFE ID {expected_spiffe}")
    spiffe_ids = dedupe([uri for match in matches for uri in match["spiffe_ids"]])
    leaf_serials = dedupe([serial for match in matches for serial in match["leaf_serials"]])
    ca_serials = dedupe([serial for match in matches for serial in match["ca_serials"]])
    if spiffe_ids != [expected_spiffe]:
        raise IdentityChainViolation(f"unexpected SPIFFE IDs from Envoy /certs: {spiffe_ids}")
    if len(leaf_serials) != 1:
        raise IdentityChainViolation(f"ambiguous leaf serials from Envoy /certs: {leaf_serials}")
    if len(ca_serials) != 1:
        raise IdentityChainViolation(f"ambiguous CA serials from Envoy /certs: {ca_serials}")
    return {
        "spiffe_id": expected_spiffe,
        "leaf_serial": leaf_serials[0],
        "root_serial": ca_serials[0],
        "raw": admin_doc,
    }


def parse_proxy_secret(secret_doc: dict[str, Any], expected_root_serial: str) -> dict[str, Any]:
    dynamic = secret_doc.get("dynamicActiveSecrets")
    static = secret_doc.get("staticSecrets") or []
    if not isinstance(dynamic, list) or not dynamic:
        raise IdentityChainViolation("Envoy proxy-config secret returned no dynamicActiveSecrets")
    if static:
        raise IdentityChainViolation("Envoy proxy-config secret exposed staticSecrets; SDS proof is not exclusive")
    names = [entry.get("name") for entry in dynamic if isinstance(entry, dict)]
    if names.count("default") != 1 or names.count("ROOTCA") != 1:
        raise IdentityChainViolation(f"expected exactly one default and one ROOTCA secret, found {names}")
    default_entry = next(entry for entry in dynamic if entry.get("name") == "default")
    root_entry = next(entry for entry in dynamic if entry.get("name") == "ROOTCA")
    chain_b64 = ((((default_entry.get("secret") or {}).get("tlsCertificate") or {}).get("certificateChain") or {}).get("inlineBytes"))
    root_b64 = ((((root_entry.get("secret") or {}).get("validationContext") or {}).get("trustedCa") or {}).get("inlineBytes"))
    if not isinstance(chain_b64, str) or not chain_b64:
        raise IdentityChainViolation("SDS default secret missing certificateChain.inlineBytes")
    if not isinstance(root_b64, str) or not root_b64:
        raise IdentityChainViolation("SDS ROOTCA missing trustedCa.inlineBytes")
    chain_pem = base64.b64decode(chain_b64).decode("utf-8", errors="ignore")
    root_pem = base64.b64decode(root_b64).decode("utf-8", errors="ignore")
    chain_certs = extract_pems(chain_pem)
    root_certs = extract_pems(root_pem)
    if len(chain_certs) < 2:
        raise IdentityChainViolation(f"expected at least two certs in SDS certificateChain, found {len(chain_certs)}")
    roots_by_serial = {inspect_cert(cert)["serial"]: cert for cert in root_certs}
    root_cert = roots_by_serial.get(normalize_serial(expected_root_serial))
    if root_cert is None:
        raise IdentityChainViolation(
            f"SDS ROOTCA bundle does not contain Envoy /certs authority serial {expected_root_serial}"
        )
    return {
        "dynamic_secret_names": ["ROOTCA", "default"],
        "leaf_pem": chain_certs[0],
        "signer_pem": chain_certs[1],
        "root_pem": root_cert,
        "root_count": len(roots_by_serial),
        "chain_count": len(chain_certs),
        "raw": secret_doc,
    }


def recycle_ready_pod(target: dict[str, str], current_pod: str) -> None:
    def wait_for_new_ready_pod(timeout_seconds: int) -> bool:
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            try:
                candidate = resolve_running_pod(target)
            except IdentityChainViolation:
                time.sleep(recycle_retry_interval_seconds)
                continue
            if candidate["pod"] and candidate["pod"] != current_pod:
                return True
            time.sleep(recycle_retry_interval_seconds)
        return False

    run([kubectl_bin, "-n", target["namespace"], "delete", "pod", current_pod, "--wait=false"], check=False)

    if wait_for_new_ready_pod(recycle_timeout_seconds):
        return

    # Recovery path for slow single-replica rollouts: force a deployment restart once.
    run(
        [
            kubectl_bin,
            "-n",
            target["namespace"],
            "rollout",
            "restart",
            target["deployment_ref"],
        ],
        check=False,
    )
    run(
        [
            kubectl_bin,
            "-n",
            target["namespace"],
            "rollout",
            "status",
            target["deployment_ref"],
            f"--timeout={recycle_timeout_seconds}s",
        ],
        check=False,
    )

    if wait_for_new_ready_pod(recycle_timeout_seconds):
        return

    raise IdentityChainViolation(
        f"timed out waiting for recycled ready istio-proxy pod for {target['namespace']}/{target['deployment']}"
    )

def certs_from_secret(secret: dict[str, Any]) -> list[str]:
    certs: list[str] = []
    for key, value in (secret.get("data") or {}).items():
        if not isinstance(value, str):
            continue
        if not any(token in key.lower() for token in ("crt", "cert", "pem")):
            continue
        try:
            decoded = base64.b64decode(value).decode("utf-8", errors="ignore")
        except Exception:
            continue
        certs.extend(extract_pems(decoded))
    return certs


def verify_allowed_ca_secret(secret: dict[str, Any], root_pem: str, root_fp: str) -> dict[str, Any]:
    name = secret.get("metadata", {}).get("name", "")
    cert_infos = []
    enforce_spire_chain = name != "istio-ca-secret"
    for cert_pem in certs_from_secret(secret):
        cert_info = inspect_cert(cert_pem)
        if enforce_spire_chain and cert_info["fingerprint"] != root_fp:
            lineage = f"{cert_info['subject']} {cert_info['issuer']}"
            if not re.search(r"\bSPIRE\b|\bSPIFFE\b", lineage, flags=re.IGNORECASE):
                raise IdentityChainViolation(
                    f"{name} contains non-SPIRE/SPIFFE certificate material: {cert_info['subject']}"
                )
        cert_infos.append(
            {
                "subject": cert_info["subject"],
                "issuer": cert_info["issuer"],
                "fingerprint": cert_info["fingerprint"],
            }
        )
    return {
        "name": name,
        "certificates": cert_infos,
        "spire_chain_enforced": enforce_spire_chain,
    }


def capture_target_once(
    target: dict[str, str],
    spire_root_pem: str,
    spire_root_info: dict[str, Any],
    allowed_root_serials: set[str],
    expected_socket_path: str | None = None,
) -> dict[str, Any]:
    pod = resolve_running_pod(target)
    expected_spiffe = f"spiffe://{trust_domain}/ns/{target['namespace']}/sa/{pod['service_account']}"
    admin_doc = load_json(
        run([kubectl_bin, "exec", "-n", target["namespace"], pod["pod"], "-c", "istio-proxy", "--", "curl", "-s", "localhost:15000/certs"]),
        f"Envoy /certs for {target['namespace']}/{target['deployment']}",
    )
    bootstrap_doc, secret_doc = load_direct_envoy_config_dump(pod["pod"], target["namespace"])

    admin_identity = parse_admin_identity(admin_doc, expected_spiffe)
    sds = parse_proxy_secret(secret_doc, admin_identity["root_serial"])
    leaf_info = inspect_cert(sds["leaf_pem"])
    signer_info = inspect_cert(sds["signer_pem"])
    root_info = inspect_cert(sds["root_pem"])
    socket_path = find_sds_socket_path(bootstrap_doc)
    if expected_socket_path is not None and socket_path != expected_socket_path:
        raise IdentityChainViolation(
            f"SDS socket path changed for {target['namespace']}/{target['deployment']}: {expected_socket_path} -> {socket_path}"
        )

    openssl_verify(sds["signer_pem"], spire_root_pem)
    openssl_verify(sds["leaf_pem"], spire_root_pem, sds["signer_pem"])

    if leaf_info["serial"] != admin_identity["leaf_serial"]:
        raise IdentityChainViolation(
            f"Envoy /certs serial {admin_identity['leaf_serial']} does not match SDS leaf serial {leaf_info['serial']} for {target['workload']}"
        )
    if root_info["serial"] != admin_identity["root_serial"]:
        raise IdentityChainViolation(
            f"Envoy /certs CA serial {admin_identity['root_serial']} does not match SDS ROOTCA serial {root_info['serial']} for {target['workload']}"
        )
    if leaf_info["issuer"] != signer_info["subject"]:
        raise IdentityChainViolation(f"leaf issuer does not match signer subject for {target['workload']}")
    if signer_info["issuer"] != spire_root_info["subject"]:
        raise IdentityChainViolation(f"signer issuer does not match SPIRE root subject for {target['workload']}")
    if root_info["serial"] not in allowed_root_serials:
        raise IdentityChainViolation(
            f"SDS ROOTCA serial {root_info['serial']} is not in allowed SPIRE-root lineage serials {sorted(allowed_root_serials)} for {target['workload']}"
        )
    # ROOTCA is authorized by membership in both the live SPIRE bundle and the
    # canonical distributed bundle. During rollover it need not be the root
    # that issued the current signer.
    if signer_info["fingerprint"] == spire_root_info["fingerprint"]:
        raise IdentityChainViolation(f"signer certificate unexpectedly equals the root for {target['workload']}")
    if expected_spiffe not in leaf_info["sans"]:
        raise IdentityChainViolation(f"SDS leaf SANs do not contain expected SPIFFE ID {expected_spiffe}")
    if "default" not in sds["dynamic_secret_names"] or "ROOTCA" not in sds["dynamic_secret_names"]:
        raise IdentityChainViolation(f"SDS dynamic secret set incomplete for {target['workload']}")

    return {
        "workload": target["workload"],
        "namespace": target["namespace"],
        "deployment": target["deployment"],
        "pod": pod["pod"],
        "service_account": pod["service_account"],
        "spiffe_id": expected_spiffe,
        "admin_leaf_serial": admin_identity["leaf_serial"],
        "admin_root_serial": admin_identity["root_serial"],
        "leaf": leaf_info,
        "signer": signer_info,
        "root": root_info,
        "chain_pem": [sds["leaf_pem"], sds["signer_pem"], sds["root_pem"]],
        "bootstrap_socket_path": socket_path,
        "dynamic_secret_names": sds["dynamic_secret_names"],
        "static_secret_count": len(secret_doc.get("staticSecrets") or []),
        "chain_verification_result": "PASS",
        "sds_delivery": "dynamicActiveSecrets",
    }


def is_identity_snapshot_mismatch(exc: IdentityChainViolation) -> bool:
    message = str(exc)
    return (
        "does not match SDS leaf serial" in message
        or "does not match SDS ROOTCA serial" in message
    )


def capture_target(
    target: dict[str, str],
    spire_root_pem: str,
    spire_root_info: dict[str, Any],
    allowed_root_serials: set[str],
    expected_socket_path: str | None = None,
) -> dict[str, Any]:
    deadline = time.monotonic() + identity_snapshot_timeout_seconds
    attempt = 1
    while True:
        try:
            return capture_target_once(
                target,
                spire_root_pem,
                spire_root_info,
                allowed_root_serials,
                expected_socket_path=expected_socket_path,
            )
        except IdentityChainViolation as exc:
            if not is_identity_snapshot_mismatch(exc) or time.monotonic() >= deadline:
                raise
            print(
                f"[identity] IDENTITY_SNAPSHOT_WAIT target={target['workload']} "
                f"attempt={attempt} max_seconds={identity_snapshot_timeout_seconds:g} "
                f"reason=certificate_rotation_between_envoy_and_sds_reads"
            )
            time.sleep(identity_snapshot_retry_interval_seconds)
            attempt += 1


def stable_workload_summary(before: dict[str, Any], after: dict[str, Any], *, proof_mode: bool) -> dict[str, Any]:
    summary = {
        "workload": before["workload"],
        "namespace": before["namespace"],
        "spiffe_id": before["spiffe_id"],
        "issuer": before["leaf"]["issuer"],
        "signer_subject": before["signer"]["subject"],
        "root_fingerprint": before["root"]["fingerprint"],
        "chain_verification_result": "PASS",
        "rotation_continuity_result": "PASS",
        "sds_source": {
            "delivery": before["sds_delivery"],
            "dynamic_secret_names": before["dynamic_secret_names"],
            "static_secret_count": before["static_secret_count"],
            "socket_path": before["bootstrap_socket_path"],
        },
    }
    if proof_mode:
        summary["rotation_continuity_witness"] = "read_only"
        summary["mutation_performed"] = False
    return summary


def write_raw_workload_artifact(
    target: dict[str, str],
    before: dict[str, Any],
    after: dict[str, Any],
    *,
    mutation_performed: bool,
) -> None:
    path = artifact_dir / f"envoy_{target['artifact_name']}.json"
    raw = {
        "workload": target["workload"],
        "namespace": target["namespace"],
        "service_account": before["service_account"],
        "spiffe_id": before["spiffe_id"],
        "run_1": before,
        "run_2": after,
        "mutation_performed": mutation_performed,
        "rotation_continuity": {
            "serial_changed": before["leaf"]["serial"] != after["leaf"]["serial"],
            "issuer_unchanged": before["leaf"]["issuer"] == after["leaf"]["issuer"],
            "root_unchanged": before["root"]["fingerprint"] == after["root"]["fingerprint"],
        },
    }
    path.write_text(json.dumps(raw, indent=2, sort_keys=True) + "\n")


def main() -> None:
    failures: list[str] = []
    try:
        spire_server_pod = os.environ.get("SPIRE_SERVER_POD", "").strip()
        if not spire_server_pod:
            raise IdentityChainViolation("SPIRE_SERVER_POD is required")
        spire_bundle_pem = run(
            [
                kubectl_bin,
                "exec",
                "-n",
                "spire-system",
                "-c",
                "spire-server",
                spire_server_pod,
                "--",
                "/opt/spire/bin/spire-server",
                "bundle",
                "show",
                "-socketPath",
                "/run/spire/private/spire-server.sock",
                "-format",
                "pem",
            ]
        )
        spire_roots = extract_pems(spire_bundle_pem)
        _, _, described_roots = select_current_spire_root(spire_roots)

        trust_state_path = repo_root / "artifacts" / "trust" / "trust_authority_state.json"
        trust_state = load_json(trust_state_path.read_text(encoding="utf-8"), "trust authority state")
        spire_root_pem = str(trust_state.get("active_root_pem") or "").strip()
        if not spire_root_pem:
            raise IdentityChainViolation("trust authority state missing active_root_pem")
        spire_root_info = inspect_cert(spire_root_pem)

        spire_csr_secret = load_json(
            run([kubectl_bin, "get", "secret", "-n", "istio-system", "spire-csr-ca", "-o", "json"], check=False),
            "secret istio-system/spire-csr-ca",
        )
        spire_cm_root_pem = run(
            [kubectl_bin, "get", "configmap", "-n", "spire-system", "spire-ca-root-cert", "-o", "jsonpath={.data.root-cert\\.pem}"],
            check=False,
        )
        if not spire_cm_root_pem.strip():
            raise IdentityChainViolation("spire-ca-root-cert missing root-cert.pem")
        spire_cm_roots = extract_pems(spire_cm_root_pem)
        csr_ca_b64 = str((spire_csr_secret.get("data") or {}).get("ca.crt") or "")
        try:
            issuance_ca_pem = base64.b64decode(csr_ca_b64).decode("utf-8")
            issuance_root_pem, root_selection = select_authorized_issuance_root(
                spire_bundle_pem,
                spire_cm_root_pem,
                issuance_ca_pem,
                openssl_bin=openssl_bin,
            )
        except (ValueError, IdentityRootError) as exc:
            raise IdentityChainViolation(str(exc)) from exc
        issuance_root_info = inspect_cert(issuance_root_pem)

        spire_bundle_payload = {
            "root_count": len(spire_roots),
            "canonical_root_count": len(spire_cm_roots),
            "active_root_serial": spire_root_info["serial"],
            "active_root_fingerprint": spire_root_info["fingerprint"],
            "issuance_root_serial": issuance_root_info["serial"],
            "issuance_root_fingerprint": issuance_root_info["fingerprint"],
            "root_selection": root_selection,
            "roots": described_roots,
        }
        spire_bundle_path.write_text(json.dumps(spire_bundle_payload, indent=2, sort_keys=True) + "\n")

        authorized_root_fps = set(root_selection["authorized_root_fingerprints"])
        allowed_root_serials = {
            inspect_cert(root)["serial"]
            for root in spire_roots
            if inspect_cert(root)["fingerprint"] in authorized_root_fps
        }
        if not allowed_root_serials:
            raise IdentityChainViolation("allowed SPIRE-root lineage serial set is empty")

        secrets_doc = load_json(run([kubectl_bin, "get", "secrets", "-n", "istio-system", "-o", "json"]), "istio secrets")
        ca_named = [item for item in secrets_doc.get("items", []) if "ca" in item.get("metadata", {}).get("name", "").lower()]
        allowed_secret_names = {"cacerts", "spire-csr-ca", "istio-ca-secret"}
        unexpected = sorted(item.get("metadata", {}).get("name", "") for item in ca_named if item.get("metadata", {}).get("name", "") not in allowed_secret_names)
        if unexpected:
            raise IdentityChainViolation(f"unexpected CA material detected in istio-system secrets: {unexpected}")
        allowed_secret_details = []
        for secret in sorted(ca_named, key=lambda item: item.get("metadata", {}).get("name", "")):
            allowed_secret_details.append(verify_allowed_ca_secret(secret, issuance_root_pem, issuance_root_info["fingerprint"]))

        workload_summaries = []
        for target in targets:
            before = capture_target(target, issuance_root_pem, issuance_root_info, allowed_root_serials)
            if proof_mode:
                after = before
            else:
                recycle_ready_pod(target, before["pod"])
                after = capture_target(
                    target,
                    issuance_root_pem,
                    issuance_root_info,
                    allowed_root_serials,
                    expected_socket_path=before["bootstrap_socket_path"],
                )
                if before["leaf"]["serial"] == after["leaf"]["serial"]:
                    raise IdentityChainViolation(f"rotation continuity failed for {target['workload']}: serial did not change")
                if before["leaf"]["issuer"] != after["leaf"]["issuer"]:
                    raise IdentityChainViolation(f"rotation continuity failed for {target['workload']}: issuer changed")
                if before["root"]["fingerprint"] != after["root"]["fingerprint"]:
                    raise IdentityChainViolation(f"rotation continuity failed for {target['workload']}: root changed")
            write_raw_workload_artifact(target, before, after, mutation_performed=not proof_mode)
            workload_summaries.append(stable_workload_summary(before, after, proof_mode=proof_mode))

        stable_summary = {
            "status": "PASS",
            "workloads_checked": [summary["workload"] for summary in workload_summaries],
            "spire_bundle": {
                "root_count": len(spire_roots),
                "active_root_fingerprint": spire_root_info["fingerprint"],
                "active_root_serial": spire_root_info["serial"],
                "issuance_root_fingerprint": issuance_root_info["fingerprint"],
                "issuance_root_serial": issuance_root_info["serial"],
                "allowed_root_serials": sorted(allowed_root_serials),
            },
            "spire_configmap_contains_issuance_root": issuance_root_info["fingerprint"] in root_selection["canonical_root_fingerprints"],
            "ca_secret_scan": {
                "allowed_secret_names": sorted(allowed_secret_names),
                "unexpected_secret_names": [],
            },
            "workloads": workload_summaries,
        }
        summary_path.write_text(json.dumps(stable_summary, indent=2, sort_keys=True) + "\n")
        proof_summary_path.write_text(json.dumps(stable_summary, indent=2, sort_keys=True) + "\n")
        print("[PASS] identity chain lineage verified: Envoy -> SPIRE signer -> SPIRE root")
    except IdentityChainViolation as exc:
        failures.append(str(exc))
        failure_path.write_text(json.dumps({"status": "FAIL", "reason": str(exc)}, indent=2) + "\n")
        print(f"[FAIL] IDENTITY_CHAIN_VIOLATION: {exc}")
        sys.exit(2)


main()
PY
