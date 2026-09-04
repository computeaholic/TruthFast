#!/usr/bin/env python3
"""ThreadForge trust authority state and metrics exporter.

This module reads the active SPIRE root and distributed trust copies,
materializes canonical trust state, and emits Prometheus-compatible metrics.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import ssl
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable


CERT_RE = re.compile(
    r"^\s*-----BEGIN (?:TRUSTED )?CERTIFICATE-----[\s\S]*?-----END (?:TRUSTED )?CERTIFICATE-----\s*$",
    re.MULTILINE,
)
_SPIRE_NOT_BEFORE_BACKDATE = timedelta(seconds=10)
SPIRE_X509_EVENT_RE = re.compile(
    r'time="(?P<time>[^"]+)".*msg="X509 CA (?P<event>prepared|activated)" '
    r'expiration="(?P<expiration>[^"]+)" issued_at="(?P<issued_at>[^"]+)" '
    r'local_authority_id=(?P<authority_id>\S+).*slot=(?P<slot>\S+)'
)


@dataclass
class CertDetails:
    pem: str
    fingerprint_sha256: str
    fingerprint_sha3_256: str
    serial: str
    subject: str
    issuer: str
    not_before: str
    not_after: str
    not_before_epoch: int
    not_after_epoch: int
    ski: str
    aki: str


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(ts: datetime) -> str:
    return ts.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_spire_log_time(value: str) -> datetime:
    primary = value.split(" +0000 UTC", 1)[0]
    if "." in primary:
        prefix, fraction = primary.split(".", 1)
        primary = f"{prefix}.{fraction[:6]}"
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(primary, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    raise RuntimeError(f"unable to parse SPIRE log timestamp: {value}")


def _run(cmd: list[str], *, input_text: str | None = None) -> str:
    proc = subprocess.run(
        cmd,
        input=input_text,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed ({proc.returncode}): {' '.join(cmd)}\\n{proc.stderr.strip()}"
        )
    return proc.stdout


def _normalize_serial(raw: str) -> str:
    value = (raw or "").strip().lower()
    if value.startswith("serial="):
        value = value.split("=", 1)[1]
    value = re.sub(r"^0+", "", value)
    return value or "0"


def _extract_pems(text: str) -> list[str]:
    cleaned = (text or "").replace("\r\n", "\n").replace("\r", "\n")
    cleaned = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", cleaned)
    pems: list[str] = []
    for m in CERT_RE.findall(cleaned):
        normalized = m.strip()
        normalized = normalized.replace("BEGIN TRUSTED CERTIFICATE", "BEGIN CERTIFICATE")
        normalized = normalized.replace("END TRUSTED CERTIFICATE", "END CERTIFICATE")
        pems.append(normalized + "\n")
    return pems


def _select_pem_from_bundle(text: str, *, active_fingerprint_sha256: str | None = None) -> str:
    pems = _extract_pems(text)
    if not pems:
        return text

    if active_fingerprint_sha256:
        for pem in pems:
            if _cert_details(pem).fingerprint_sha256 == active_fingerprint_sha256:
                return pem

    return pems[0]


def _openssl_x509_fields(pem: str) -> dict[str, str]:
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as fh:
        fh.write(pem if pem.endswith("\n") else pem + "\n")
        cert_path = fh.name
    try:
        out = _run([
            "openssl",
            "x509",
            "-in",
            cert_path,
            "-noout",
            "-serial",
            "-subject",
            "-issuer",
            "-startdate",
            "-enddate",
            "-ext",
            "subjectKeyIdentifier",
            "-ext",
            "authorityKeyIdentifier",
        ])
    finally:
        Path(cert_path).unlink(missing_ok=True)

    fields: dict[str, str] = {}
    current_ext = ""
    for line in out.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith("serial="):
            fields["serial"] = _normalize_serial(s)
            continue
        if s.startswith("subject="):
            fields["subject"] = s.split("=", 1)[1].strip()
            continue
        if s.startswith("issuer="):
            fields["issuer"] = s.split("=", 1)[1].strip()
            continue
        if s.startswith("notBefore="):
            fields["notBefore"] = s.split("=", 1)[1].strip()
            continue
        if s.startswith("notAfter="):
            fields["notAfter"] = s.split("=", 1)[1].strip()
            continue

        if "X509v3 Subject Key Identifier" in s:
            current_ext = "ski"
            continue
        if "X509v3 Authority Key Identifier" in s:
            current_ext = "aki"
            continue

        if current_ext == "ski":
            fields["ski"] = s.replace(":", "").lower()
            current_ext = ""
        elif current_ext == "aki":
            if "keyid:" in s.lower():
                kid = s.split(":", 1)[1].strip()
                fields["aki"] = kid.replace(":", "").lower()
            else:
                fields["aki"] = s.replace(":", "").lower()
            current_ext = ""

    return fields


def _parse_openssl_time(value: str) -> datetime:
    # Example: Apr 22 20:36:15 2026 GMT
    return datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)


def _cert_details(pem: str) -> CertDetails:
    der = ssl.PEM_cert_to_DER_cert(pem)
    fp256 = hashlib.sha256(der).hexdigest()
    fp3 = hashlib.sha3_256(der).hexdigest()
    fields = _openssl_x509_fields(pem)

    not_before = _parse_openssl_time(fields["notBefore"])
    not_after = _parse_openssl_time(fields["notAfter"])

    return CertDetails(
        pem=pem,
        fingerprint_sha256=fp256,
        fingerprint_sha3_256=fp3,
        serial=fields.get("serial", "0"),
        subject=fields.get("subject", ""),
        issuer=fields.get("issuer", ""),
        not_before=_iso(not_before),
        not_after=_iso(not_after),
        not_before_epoch=int(not_before.timestamp()),
        not_after_epoch=int(not_after.timestamp()),
        ski=fields.get("ski", ""),
        aki=fields.get("aki", ""),
    )


def _kubectl_jsonpath(path: str, namespace: str, name: str) -> str:
    return _run(
        [
            "kubectl",
            "get",
            path,
            name,
            "-n",
            namespace,
            "-o",
            "jsonpath={.data.root-cert\\.pem}",
        ]
    ).strip()


def _first_ready_pod(namespace: str, selector: str) -> str:
    raw = _run(
        [
            "kubectl",
            "get",
            "pods",
            "-n",
            namespace,
            "-l",
            selector,
            "-o",
            "json",
        ]
    )
    doc = json.loads(raw)
    items = doc.get("items", [])

    def _is_ready(item: dict[str, Any]) -> bool:
        if item.get("status", {}).get("phase") != "Running":
            return False
        for cond in item.get("status", {}).get("conditions", []):
            if cond.get("type") == "Ready" and cond.get("status") == "True":
                return True
        return False

    for item in items:
        if _is_ready(item):
            name = str(item.get("metadata", {}).get("name", "")).strip()
            if name:
                return name

    if items:
        # Fallback to first pod name to preserve behavior when readiness is unavailable.
        name = str(items[0].get("metadata", {}).get("name", "")).strip()
        if name:
            return name

    raise RuntimeError(f"no pod found for {namespace}/{selector}")


def _kubectl_exec(namespace: str, pod: str, command: list[str], container: str | None = None) -> str:
    cmd = ["kubectl", "exec", "-n", namespace, pod]
    if container:
        cmd.extend(["-c", container])
    cmd.extend(["--", *command])
    return _run(cmd)


def _kubectl_exec_first_success(
    namespace: str,
    pod: str,
    commands: list[list[str]],
    container: str | None = None,
) -> str:
    errors: list[str] = []
    for command in commands:
        try:
            return _kubectl_exec(namespace, pod, command, container=container)
        except Exception as exc:
            errors.append(str(exc))
    raise RuntimeError("; ".join(errors) if errors else "no command candidates provided")


def _collect_active_root_bundle() -> tuple[str, CertDetails, int, int]:
    server_pod = _first_ready_pod("spire-system", "app=spire-server")
    bundle = _kubectl_exec_first_success(
        "spire-system",
        server_pod,
        [
            [
                "/opt/spire/bin/spire-server",
                "bundle",
                "show",
                "-socketPath",
                "/run/spire/data/server.sock",
                "-format",
                "pem",
            ],
            [
                "/opt/spire/bin/spire-server",
                "bundle",
                "show",
                "-socketPath",
                "/run/spire/private/spire-server.sock",
                "-format",
                "pem",
            ],
        ],
        container="spire-server",
    )
    pems = _extract_pems(bundle)
    if not pems:
        debug_path = Path(
            os.environ.get(
                "TRUST_AUTHORITY_BUNDLE_DEBUG_PATH",
                "artifacts/trust/trust_authority_bundle_raw.txt",
            )
        )
        try:
            debug_path.parent.mkdir(parents=True, exist_ok=True)
            debug_path.write_text(bundle if bundle.endswith("\n") else bundle + "\n", encoding="utf-8")
            debug_ref = str(debug_path)
        except Exception:
            debug_ref = "unavailable"
        raise RuntimeError(f"SPIRE bundle contained no certificates (raw_bundle={debug_ref})")

    now = _utc_now()
    valid: list[tuple[int, CertDetails]] = []
    for pem in pems:
        details = _cert_details(pem)
        if details.not_before_epoch <= int(now.timestamp()) <= details.not_after_epoch:
            valid.append((details.not_before_epoch, details))
    if not valid:
        raise RuntimeError("SPIRE bundle contains no currently valid certificate")
    active = _select_spire_lifecycle_active_root([item[1] for item in valid])
    return bundle, active, len(pems), len(valid)


def _collect_active_root() -> tuple[CertDetails, int, int]:
    bundle, active, total, valid = _collect_active_root_bundle()
    return active, total, valid


def _select_spire_lifecycle_active_root(valid_roots: list[CertDetails]) -> CertDetails:
    server_pod = _first_ready_pod("spire-system", "app=spire-server")
    logs = _run(
        [
            "kubectl",
            "-n",
            "spire-system",
            "logs",
            server_pod,
            "-c",
            "spire-server",
            "--since=72h",
        ]
    )
    active_event: dict[str, str] | None = None
    for line in logs.splitlines():
        match = SPIRE_X509_EVENT_RE.search(line)
        if not match or match.group("event") != "activated":
            continue
        issued_at = _parse_spire_log_time(match.group("issued_at"))
        expiration = _parse_spire_log_time(match.group("expiration"))
        active_event = {
            "not_before": _iso(issued_at.replace(microsecond=0) - _SPIRE_NOT_BEFORE_BACKDATE),
            "not_after": _iso(expiration),
        }

    if active_event is None:
        raise RuntimeError("unable to observe SPIRE ACTIVE X509 authority from ca_manager logs")

    for root in valid_roots:
        if root.not_after == active_event["not_after"]:
            return root

    raise RuntimeError("SPIRE ACTIVE X509 authority was not found in authoritative bundle")


def _safe_collect(name: str, collector: Callable[[], str]) -> dict[str, Any]:
    try:
        pem = collector()
        if not pem.strip():
            return {"name": name, "present": False, "error": "empty certificate payload"}
        cert = _cert_details(pem)
        return {
            "name": name,
            "present": True,
            "fingerprint_sha256": cert.fingerprint_sha256,
            "fingerprint_sha3_256": cert.fingerprint_sha3_256,
            "serial": cert.serial,
            "not_before": cert.not_before,
            "not_after": cert.not_after,
            "ski": cert.ski,
            "aki": cert.aki,
        }
    except Exception as exc:
        return {"name": name, "present": False, "error": str(exc)}


def _load_json(path: Path, default: dict[str, Any]) -> dict[str, Any]:
    if not path.exists():
        return default
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default
    if not isinstance(value, dict):
        return default
    return value


def _openssl_verify(leaf_pem: str, root_pem: str, untrusted_pem: str | None = None) -> bool:
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        leaf_path = temp / "leaf.pem"
        root_path = temp / "root.pem"
        leaf_path.write_text(leaf_pem, encoding="utf-8")
        root_path.write_text(root_pem, encoding="utf-8")
        cmd = ["openssl", "verify", "-CAfile", str(root_path)]
        if untrusted_pem:
            signer_path = temp / "signer.pem"
            signer_path.write_text(untrusted_pem, encoding="utf-8")
            cmd.extend(["-untrusted", str(signer_path)])
        cmd.append(str(leaf_path))
        proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
        return proc.returncode == 0 and f"{leaf_path}: OK" in proc.stdout


def _extract_pem_field(doc: dict[str, Any], path: list[str]) -> str:
    current: Any = doc
    for key in path:
        if not isinstance(current, dict):
            return ""
        current = current.get(key)
    if not isinstance(current, str):
        return ""
    return current.strip()


def _ingress_observation_failure(pod: str, error: str) -> dict[str, Any]:
    return {
        "name": "istio-ingressgateway",
        "namespace": "istio-system",
        "kind": "deployment",
        "remediation_target": "",
        "pod": pod,
        "source": "envoy-admin:/certs",
        "present": True,
        "observation_status": "UNOBSERVABLE",
        "lineage_matches_active_root": False,
        "signer_chains_to_active_root": False,
        "leaf_chains_to_active_root": False,
        "root_matches_active_root": False,
        "restart_required": False,
        "error": error,
    }


def _collect_ingressgateway_consumer(active: CertDetails) -> dict[str, Any]:
    namespace = "istio-system"
    try:
        pod = _first_ready_pod(namespace, "app=istio-ingressgateway")
    except RuntimeError as exc:
        if str(exc).startswith("no pod found for "):
            raise
        return _ingress_observation_failure("", f"ingressgateway pod discovery failed: {exc}")

    # Envoy's admin endpoint is the load-bearing consumer view. It exposes the
    # active leaf/CA serials and SPIFFE SANs, but intentionally not certificate PEMs.
    try:
        raw = _kubectl_exec(
            namespace,
            pod,
            ["curl", "-fsS", "--max-time", "5", "http://127.0.0.1:15000/certs"],
            container="istio-proxy",
        )
        document = json.loads(raw)
    except Exception as exc:
        return _ingress_observation_failure(pod, f"Envoy /certs observation failed: {exc}")

    expected_uri = (
        f"spiffe://{os.environ.get('SPIFFE_TRUST_DOMAIN', 'identity.threadforge.local')}"
        "/ns/istio-system/sa/istio-ingressgateway"
    )
    observed_leaf: dict[str, Any] | None = None
    observed_root: dict[str, Any] | None = None
    for certificate in document.get("certificates", []):
        if not isinstance(certificate, dict):
            continue
        leaf = next(
            (
                entry
                for entry in certificate.get("cert_chain", [])
                if isinstance(entry, dict)
                and expected_uri in {
                    str(san.get("uri", ""))
                    for san in entry.get("subject_alt_names", [])
                    if isinstance(san, dict)
                }
            ),
            None,
        )
        root = next(
            (
                entry
                for entry in certificate.get("ca_cert", [])
                if isinstance(entry, dict) and str(entry.get("serial_number", "")).strip()
            ),
            None,
        )
        if leaf is not None and root is not None:
            observed_leaf = leaf
            observed_root = root
            break

    if observed_leaf is None or observed_root is None:
        return _ingress_observation_failure(
            pod,
            "Envoy /certs response did not contain the expected gateway leaf and trusted CA",
        )

    leaf_serial = _normalize_serial(str(observed_leaf.get("serial_number", "")))
    root_serial = _normalize_serial(str(observed_root.get("serial_number", "")))
    active_serial = _normalize_serial(active.serial)
    root_matches_active = root_serial == active_serial
    converged = bool(leaf_serial and root_matches_active)
    return {
        "name": "istio-ingressgateway",
        "namespace": namespace,
        "kind": "deployment",
        "remediation_target": "deployment/istio-ingressgateway",
        "pod": pod,
        "source": "envoy-admin:/certs",
        "present": True,
        "observation_status": "OBSERVED",
        "leaf_serial": leaf_serial,
        "leaf_subject_alt_name": expected_uri,
        "leaf_valid_from": str(observed_leaf.get("valid_from", "")),
        "leaf_expiration_time": str(observed_leaf.get("expiration_time", "")),
        "signer_serial": "",
        "signer_subject": "",
        "signer_issuer": "",
        "root_serial": root_serial,
        "root_subject_alt_name": str(
            next(
                (
                    san.get("uri", "")
                    for san in observed_root.get("subject_alt_names", [])
                    if isinstance(san, dict) and san.get("uri")
                ),
                "",
            )
        ),
        "lineage_matches_active_root": converged,
        "signer_chains_to_active_root": root_matches_active,
        "leaf_chains_to_active_root": root_matches_active,
        "root_matches_active_root": root_matches_active,
        "restart_required": not converged,
        "error": "",
    }


def _collect_istiod_consumer(active: CertDetails) -> dict[str, Any]:
    namespace = "istio-system"
    secret_doc = json.loads(_run(["kubectl", "get", "secret", "istiod-tls", "-n", namespace, "-o", "json"]))
    data = secret_doc.get("data") or {}
    tls_crt_b64 = str(data.get("tls.crt", "")).strip()
    ca_crt_b64 = str(data.get("ca.crt", "")).strip()
    if not tls_crt_b64 or not ca_crt_b64:
        raise RuntimeError("istiod-tls missing tls.crt or ca.crt")
    tls_pems = _extract_pems(base64.b64decode(tls_crt_b64).decode("utf-8", errors="ignore"))
    ca_pem = _select_pem_from_bundle(
        base64.b64decode(ca_crt_b64).decode("utf-8", errors="ignore"),
        active_fingerprint_sha256=active.fingerprint_sha256,
    )
    ca_pems = _extract_pems(ca_pem)
    if not tls_pems or len(ca_pems) != 1:
        raise RuntimeError("istiod-tls returned malformed certificate material")

    leaf = _cert_details(tls_pems[0])
    root = _cert_details(ca_pems[0])
    leaf_chains = _openssl_verify(leaf.pem, active.pem)
    root_matches_active = root.fingerprint_sha256 == active.fingerprint_sha256
    converged = leaf_chains and root_matches_active
    return {
        "name": "istiod",
        "namespace": namespace,
        "kind": "deployment",
        "remediation_target": "deployment/istiod",
        "pod": _first_ready_pod(namespace, "app=istiod"),
        "source": "secret:istiod-tls",
        "leaf_serial": leaf.serial,
        "leaf_subject": leaf.subject,
        "leaf_issuer": leaf.issuer,
        "signer_serial": active.serial,
        "signer_subject": active.subject,
        "signer_issuer": active.issuer,
        "root_serial": root.serial,
        "root_subject": root.subject,
        "lineage_matches_active_root": converged,
        "signer_chains_to_active_root": True,
        "leaf_chains_to_active_root": leaf_chains,
        "root_matches_active_root": root_matches_active,
        "restart_required": not converged,
        "error": "",
    }


def _safe_collect_consumer(
    name: str,
    collector: Callable[[CertDetails], dict[str, Any]],
    active: CertDetails,
) -> dict[str, Any]:
    try:
        row = collector(active)
        row["present"] = True
        row.setdefault("observation_status", "OBSERVED")
        return row
    except Exception as exc:
        return {
            "name": name,
            "namespace": "",
            "kind": "",
            "remediation_target": "",
            "pod": "",
            "source": "",
            "present": False,
            "observation_status": "ABSENT",
            "lineage_matches_active_root": False,
            "signer_chains_to_active_root": False,
            "leaf_chains_to_active_root": False,
            "root_matches_active_root": False,
            "restart_required": False,
            "error": str(exc),
        }


def _compute_publication_timestamp(
    prev_state: dict[str, Any],
    active_fp: str,
    source_map: dict[str, dict[str, Any]],
    now_iso: str,
) -> str:
    aligned = (
        source_map.get("spire-ca-root-cert", {}).get("fingerprint_sha256") == active_fp
        and source_map.get("istio-ca-root-cert", {}).get("fingerprint_sha256") == active_fp
    )
    prev_pub = str(prev_state.get("publication_timestamp", "")).strip()
    prev_active = str(prev_state.get("active_root_fingerprint", "")).strip()

    if not aligned:
        return prev_pub

    if prev_pub and prev_active == active_fp:
        return prev_pub

    return now_iso


def _write_metrics(
    metrics_path: Path,
    state: dict[str, Any],
    counters: dict[str, Any],
) -> None:
    root_age = float(state.get("root_age_seconds", 0.0) or 0.0)
    pub_age = float(state.get("publication_age_seconds", 0.0) or 0.0)
    drift = float(state.get("publication_drift", 0.0) or 0.0)
    expiry = float(state.get("root_expiration_seconds", 0.0) or 0.0)
    success_total = float(counters.get("success_total", 0.0) or 0.0)
    failure_total = float(counters.get("failure_total", 0.0) or 0.0)
    last_run_epoch = float(counters.get("last_run_epoch", 0.0) or 0.0)
    last_outcome_success = 1.0 if str(counters.get("last_result", "")).lower() in {"success", "no_drift"} else 0.0
    now_epoch = float(state.get("generated_at_epoch", 0.0) or 0.0)
    last_run_age = max(0.0, now_epoch - last_run_epoch) if last_run_epoch > 0 else 0.0
    publication_timestamp_set = 1.0 if str(state.get("publication_timestamp", "")).strip() else 0.0
    bundle_total = float(state.get("active_bundle_cert_count", 0.0) or 0.0)
    bundle_valid = float(state.get("active_bundle_valid_cert_count", 0.0) or 0.0)
    mismatch_count = float(state.get("source_mismatch_count", 0.0) or 0.0)
    consumer_convergence = 1.0 if bool(state.get("consumer_convergence_ok")) else 0.0
    consumer_restart_required = 1.0 if bool(state.get("consumer_restart_required")) else 0.0

    warning = 1.0 if expiry < 24 * 3600 else 0.0
    critical = 1.0 if expiry < 12 * 3600 else 0.0
    emergency = 1.0 if expiry < 3600 else 0.0

    lines = [
        "# HELP threadforge_trust_root_age_seconds Age of active trust root in seconds.",
        "# TYPE threadforge_trust_root_age_seconds gauge",
        f"threadforge_trust_root_age_seconds {root_age:.6f}",
        "# HELP threadforge_trust_publication_age_seconds Seconds since trust publication was observed aligned.",
        "# TYPE threadforge_trust_publication_age_seconds gauge",
        f"threadforge_trust_publication_age_seconds {pub_age:.6f}",
        "# HELP threadforge_trust_publication_drift 1 when distributed trust differs from active root.",
        "# TYPE threadforge_trust_publication_drift gauge",
        f"threadforge_trust_publication_drift {drift:.6f}",
        "# HELP threadforge_trust_root_expiration_seconds Seconds until active trust root expiration.",
        "# TYPE threadforge_trust_root_expiration_seconds gauge",
        f"threadforge_trust_root_expiration_seconds {expiry:.6f}",
        "# HELP threadforge_trust_reconciliation_success_total Total successful trust reconciliations.",
        "# TYPE threadforge_trust_reconciliation_success_total counter",
        f"threadforge_trust_reconciliation_success_total {success_total:.6f}",
        "# HELP threadforge_trust_reconciliation_failure_total Total failed trust reconciliations.",
        "# TYPE threadforge_trust_reconciliation_failure_total counter",
        f"threadforge_trust_reconciliation_failure_total {failure_total:.6f}",
        "# HELP threadforge_trust_reconciliation_last_run_age_seconds Seconds since last reconciliation cycle completion.",
        "# TYPE threadforge_trust_reconciliation_last_run_age_seconds gauge",
        f"threadforge_trust_reconciliation_last_run_age_seconds {last_run_age:.6f}",
        "# HELP threadforge_trust_reconciliation_last_outcome_success 1 when last reconciliation outcome was success/no_drift, else 0.",
        "# TYPE threadforge_trust_reconciliation_last_outcome_success gauge",
        f"threadforge_trust_reconciliation_last_outcome_success {last_outcome_success:.6f}",
        "# HELP threadforge_trust_expiration_warning 1 when root expires in <24h.",
        "# TYPE threadforge_trust_expiration_warning gauge",
        f"threadforge_trust_expiration_warning {warning:.6f}",
        "# HELP threadforge_trust_expiration_critical 1 when root expires in <12h.",
        "# TYPE threadforge_trust_expiration_critical gauge",
        f"threadforge_trust_expiration_critical {critical:.6f}",
        "# HELP threadforge_trust_expiration_emergency 1 when root expires in <1h.",
        "# TYPE threadforge_trust_expiration_emergency gauge",
        f"threadforge_trust_expiration_emergency {emergency:.6f}",
        "# HELP threadforge_trust_publication_timestamp_set 1 when publication_timestamp is set, else 0.",
        "# TYPE threadforge_trust_publication_timestamp_set gauge",
        f"threadforge_trust_publication_timestamp_set {publication_timestamp_set:.6f}",
        "# HELP threadforge_trust_active_bundle_cert_count Number of certificates observed in active SPIRE bundle.",
        "# TYPE threadforge_trust_active_bundle_cert_count gauge",
        f"threadforge_trust_active_bundle_cert_count {bundle_total:.6f}",
        "# HELP threadforge_trust_active_bundle_valid_cert_count Number of currently valid certificates observed in active SPIRE bundle.",
        "# TYPE threadforge_trust_active_bundle_valid_cert_count gauge",
        f"threadforge_trust_active_bundle_valid_cert_count {bundle_valid:.6f}",
        "# HELP threadforge_trust_source_mismatch_count Number of trust sources that do not match active root.",
        "# TYPE threadforge_trust_source_mismatch_count gauge",
        f"threadforge_trust_source_mismatch_count {mismatch_count:.6f}",
        "# HELP threadforge_trust_consumer_convergence_ok 1 when all critical consumers chain to the active trust lineage.",
        "# TYPE threadforge_trust_consumer_convergence_ok gauge",
        f"threadforge_trust_consumer_convergence_ok {consumer_convergence:.6f}",
        "# HELP threadforge_trust_consumer_restart_required 1 when any critical consumer requires restart/remediation for lineage convergence.",
        "# TYPE threadforge_trust_consumer_restart_required gauge",
        f"threadforge_trust_consumer_restart_required {consumer_restart_required:.6f}",
        "",
    ]

    for source in state.get("sources", []):
        name = str(source.get("name", "unknown")).replace('"', '\\"')
        present = 1.0 if bool(source.get("present")) else 0.0
        match = 1.0 if bool(source.get("matches_active_root")) else 0.0
        lines.append(f"threadforge_trust_source_present{{source=\"{name}\"}} {present:.6f}")
        lines.append(f"threadforge_trust_source_match{{source=\"{name}\"}} {match:.6f}")

    for consumer in state.get("critical_consumers", []):
        name = str(consumer.get("name", "unknown")).replace('"', '\\"')
        present = 1.0 if bool(consumer.get("present")) else 0.0
        match = 1.0 if bool(consumer.get("lineage_matches_active_root")) else 0.0
        restart = 1.0 if bool(consumer.get("restart_required")) else 0.0
        lines.append(f"threadforge_trust_consumer_present{{consumer=\"{name}\"}} {present:.6f}")
        lines.append(f"threadforge_trust_consumer_lineage_match{{consumer=\"{name}\"}} {match:.6f}")
        lines.append(f"threadforge_trust_consumer_restart_required{{consumer=\"{name}\"}} {restart:.6f}")

    lines.append("")
    metrics_path.parent.mkdir(parents=True, exist_ok=True)
    metrics_path.write_text("\n".join(lines), encoding="utf-8")


def export_state(state_path: Path, metrics_path: Path, counters_path: Path) -> int:
    now = _utc_now()
    now_iso = _iso(now)
    now_epoch = int(now.timestamp())

    bundle_text, active, bundle_cert_count, bundle_valid_cert_count = _collect_active_root_bundle()
    bundle_sha256 = hashlib.sha256(bundle_text.encode("utf-8")).hexdigest()
    source_rows = [
        _safe_collect(
            "spire-ca-root-cert",
            lambda: _select_pem_from_bundle(
                _kubectl_jsonpath("configmap", "spire-system", "spire-ca-root-cert"),
                active_fingerprint_sha256=active.fingerprint_sha256,
            ),
        ),
        _safe_collect(
            "istio-ca-root-cert",
            lambda: _select_pem_from_bundle(
                _kubectl_jsonpath("configmap", "istio-system", "istio-ca-root-cert"),
                active_fingerprint_sha256=active.fingerprint_sha256,
            ),
        ),
        _safe_collect(
            "istiod-mounted-root",
            lambda: _select_pem_from_bundle(
                _kubectl_exec_first_success(
                    "istio-system",
                    _first_ready_pod("istio-system", "app=istiod"),
                    [
                        ["cat", "/var/run/secrets/istio/root-cert.pem"],
                        ["cat", "/etc/cacerts/root-cert.pem"],
                        ["cat", "/etc/istio/root-cert.pem"],
                    ],
                    container="discovery",
                ),
                active_fingerprint_sha256=active.fingerprint_sha256,
            ),
        ),
        _safe_collect(
            "workload-mounted-root",
            lambda: _select_pem_from_bundle(
                _kubectl_exec_first_success(
                    "threadforge-test",
                    _first_ready_pod("threadforge-test", "app=echo"),
                    [
                        ["cat", "/etc/certs/root-cert.pem"],
                        ["cat", "/var/run/secrets/istio/root-cert.pem"],
                        ["cat", "/etc/istio/root-cert.pem"],
                    ],
                    container="istio-proxy",
                ),
                active_fingerprint_sha256=active.fingerprint_sha256,
            ),
        ),
    ]

    source_map = {row["name"]: row for row in source_rows}
    for row in source_rows:
        row["matches_active_root"] = (
            bool(row.get("present"))
            and row.get("fingerprint_sha256") == active.fingerprint_sha256
        )

    prev_state = _load_json(state_path, {})
    counters = _load_json(counters_path, {"success_total": 0, "failure_total": 0})

    publication_ts = _compute_publication_timestamp(
        prev_state,
        active.fingerprint_sha256,
        source_map,
        now_iso,
    )
    publication_age = 0
    if publication_ts:
        try:
            pub_dt = datetime.fromisoformat(publication_ts.replace("Z", "+00:00"))
            publication_age = max(0, int(now.timestamp() - pub_dt.timestamp()))
        except Exception:
            publication_age = 0

    all_aligned = all(bool(row.get("matches_active_root")) for row in source_rows)
    mismatch_count = sum(1 for row in source_rows if not bool(row.get("matches_active_root")))
    publication_drift = 0 if all_aligned else 1
    critical_consumers = [
        _safe_collect_consumer("istiod", _collect_istiod_consumer, active),
        _safe_collect_consumer("istio-ingressgateway", _collect_ingressgateway_consumer, active),
    ]
    consumer_convergence_ok = all(
        bool(row.get("present")) and bool(row.get("lineage_matches_active_root"))
        for row in critical_consumers
    )
    consumer_restart_required = any(bool(row.get("restart_required")) for row in critical_consumers)

    state = {
        "generated_at": now_iso,
        "source_observed_at": now_iso,
        "generated_at_epoch": now_epoch,
        "source_observed_at_epoch": now_epoch,
        "active_root_fingerprint": active.fingerprint_sha256,
        "active_root_fingerprint_sha3_256": active.fingerprint_sha3_256,
        "active_root_serial": active.serial,
        "active_root_pem": active.pem,
        "active_root_not_before": active.not_before,
        "active_root_not_after": active.not_after,
        "active_root_ski": active.ski,
        "active_root_aki": active.aki,
        "active_root_epoch_not_before": active.not_before_epoch,
        "active_root_epoch_not_after": active.not_after_epoch,
        "root_age_seconds": max(0, now_epoch - active.not_before_epoch),
        "root_expiration_seconds": active.not_after_epoch - now_epoch,
        "publication_timestamp": publication_ts,
        "publication_age_seconds": publication_age,
        "publication_drift": publication_drift,
        "publication_complete": all_aligned,
        "active_bundle_cert_count": bundle_cert_count,
        "active_bundle_valid_cert_count": bundle_valid_cert_count,
        "spire_bundle_sha256": bundle_sha256,
        "source_mismatch_count": mismatch_count,
        "all_sources_aligned": all_aligned,
        "consumer_convergence_ok": consumer_convergence_ok,
        "consumer_restart_required": consumer_restart_required,
        "critical_consumers": critical_consumers,
        "sources": source_rows,
    }

    state_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_state_path = state_path.with_suffix(state_path.suffix + f".tmp-{os.getpid()}-{time.time_ns()}")
    tmp_state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp_state_path.replace(state_path)
    _write_metrics(metrics_path, state, counters)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="ThreadForge trust authority exporter")
    parser.add_argument("command", choices=["export-state"])
    parser.add_argument(
        "--state-path",
        default="artifacts/trust/trust_authority_state.json",
        help="Path to trust authority state JSON",
    )
    parser.add_argument(
        "--metrics-path",
        default="artifacts/trust/trust_authority_metrics.prom",
        help="Path to metrics output file",
    )
    parser.add_argument(
        "--counters-path",
        default="artifacts/trust/reconciler_counters.json",
        help="Path to reconciliation counters JSON",
    )

    args = parser.parse_args(argv)
    state_path = Path(args.state_path)
    metrics_path = Path(args.metrics_path)
    counters_path = Path(args.counters_path)

    if args.command == "export-state":
        return export_state(state_path, metrics_path, counters_path)

    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as exc:
        print(f"[FAIL] TRUST_AUTHORITY_ERROR: {exc}")
        raise SystemExit(2)
