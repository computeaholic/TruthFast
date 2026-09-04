#!/usr/bin/env python3
"""Validate SPIRE-native trust-root successor continuity.

This script observes SPIRE-owned state only. It does not generate roots, write
keys, or mutate trust bundles.
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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


CERT_RE = re.compile(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----")


def run(cmd: list[str], *, input_bytes: bytes | None = None) -> bytes:
    proc = subprocess.run(cmd, input=input_bytes, capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", errors="replace").strip())
    return proc.stdout


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_time(value: str) -> datetime:
    return datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)


def extract_pems(text: str) -> list[str]:
    return [match.strip() + "\n" for match in CERT_RE.findall(text or "")]


def pubkey_fingerprint_from_cert(pem: str) -> str:
    pub = run(["openssl", "x509", "-pubkey", "-noout"], input_bytes=pem.encode("utf-8"))
    der = run(["openssl", "ec", "-pubin", "-in", "/dev/stdin", "-pubout", "-outform", "DER"], input_bytes=pub)
    return hashlib.sha256(der).hexdigest()


def pubkey_fingerprint_from_key_der(key_der: bytes) -> str | None:
    with tempfile.NamedTemporaryFile(suffix=".der", delete=False) as fh:
        fh.write(key_der)
        key_path = fh.name
    try:
        pub = run(["openssl", "ec", "-inform", "DER", "-in", key_path, "-pubout", "-outform", "PEM"])
        der = run(["openssl", "ec", "-pubin", "-in", "/dev/stdin", "-pubout", "-outform", "DER"], input_bytes=pub)
        return hashlib.sha256(der).hexdigest()
    except Exception:
        return None
    finally:
        Path(key_path).unlink(missing_ok=True)


def parse_cert(pem: str) -> dict[str, Any]:
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as fh:
        fh.write(pem)
        path = fh.name
    try:
        out = run(["openssl", "x509", "-in", path, "-noout", "-serial", "-subject", "-issuer", "-startdate", "-enddate"]).decode()
    finally:
        Path(path).unlink(missing_ok=True)

    fields: dict[str, str] = {}
    for line in out.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key.strip()] = value.strip()

    der = ssl.PEM_cert_to_DER_cert(pem)
    not_before = parse_time(fields["notBefore"])
    not_after = parse_time(fields["notAfter"])
    return {
        "pem": pem,
        "fingerprint_sha256": hashlib.sha256(der).hexdigest(),
        "public_key_sha256": pubkey_fingerprint_from_cert(pem),
        "serial": fields.get("serial", "").lower(),
        "subject": fields.get("subject", ""),
        "issuer": fields.get("issuer", ""),
        "not_before": not_before,
        "not_after": not_after,
    }


def load_keys(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    key_fps: dict[str, str] = {}
    for name, value in (data.get("keys") or {}).items():
        if not str(name).startswith("x509-CA"):
            continue
        try:
            der = base64.b64decode(str(value))
        except Exception:
            continue
        fp = pubkey_fingerprint_from_key_der(der)
        if fp:
            key_fps[str(name)] = fp
    return key_fps


def validate(bundle_text: str, keys_path: Path, minimum_successor_count: int, minimum_overlap_hours: float) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    errors: list[str] = []
    roots: list[dict[str, Any]] = []
    for index, pem in enumerate(extract_pems(bundle_text)):
        try:
            roots.append(parse_cert(pem))
        except Exception as exc:
            errors.append(f"root[{index}] parse_error: {exc}")

    valid_roots = [root for root in roots if root["not_before"] <= now <= root["not_after"]]
    expired_roots = [root for root in roots if root["not_after"] < now]
    active_root = max(valid_roots, key=lambda root: root["not_before"], default=None)
    horizon = max((root["not_after"] for root in valid_roots), default=None)
    successor_roots: list[dict[str, Any]] = []
    if horizon is not None:
        minimum_overlap_seconds = minimum_overlap_hours * 3600
        for root in roots:
            overlap_seconds = (horizon - root["not_before"]).total_seconds()
            if root["not_after"] > horizon and overlap_seconds >= minimum_overlap_seconds:
                successor_roots.append(root)

    if active_root is None:
        errors.append("active root missing")
    if len(successor_roots) < minimum_successor_count:
        errors.append(f"successor_count {len(successor_roots)} below policy minimum {minimum_successor_count}")

    key_fps = load_keys(keys_path)
    key_fp_set = set(key_fps.values())
    non_expired_roots = [root for root in roots if root["not_after"] >= now]
    missing_key_roots = [root for root in non_expired_roots if root["public_key_sha256"] not in key_fp_set]
    for root in missing_key_roots:
        errors.append(f"missing SPIRE-owned x509 CA key for non-expired root serial={root['serial']}")

    duplicate_serials = {
        root["serial"]
        for root in roots
        if root["serial"] and sum(1 for candidate in roots if candidate["serial"] == root["serial"]) > 1
    }
    for serial in sorted(duplicate_serials):
        errors.append(f"duplicate root serial {serial}")

    successor_serials = {root["serial"] for root in successor_roots}
    active_serial = active_root["serial"] if active_root else ""
    root_rows = []
    for root in roots:
        if root["not_after"] < now:
            state = "EXPIRED"
        elif root["serial"] == active_serial:
            state = "ACTIVE"
        elif root["serial"] in successor_serials:
            state = "SUCCESSOR"
        elif root["not_before"] > now:
            state = "FUTURE"
        else:
            state = "CURRENT_VALID_NON_ACTIVE"
        root_rows.append(
            {
                "fingerprint_sha256": root["fingerprint_sha256"],
                "public_key_sha256": root["public_key_sha256"],
                "serial": root["serial"],
                "subject": root["subject"],
                "issuer": root["issuer"],
                "not_before": iso(root["not_before"]),
                "not_after": iso(root["not_after"]),
                "lifecycle_state": state,
                "spire_key_present": root["public_key_sha256"] in key_fp_set,
            }
        )

    continuity_ok = not errors
    return {
        "generated_at": iso(now),
        "authority": "spire-server-own-trust-domain-bundle",
        "mutation_performed": False,
        "active_root_present": active_root is not None,
        "active_root_serial": active_serial,
        "successor_count": len(successor_roots),
        "successor_published": len(successor_roots) >= minimum_successor_count,
        "successor_key_available": all(root["public_key_sha256"] in key_fp_set for root in successor_roots),
        "successor_overlap_valid": len(successor_roots) >= minimum_successor_count,
        "bundle_publication_valid": not any("parse_error" in error for error in errors),
        "key_availability_valid": not missing_key_roots,
        "lifecycle_continuity_preserved": active_root is not None and len(successor_roots) >= minimum_successor_count,
        "continuity_ok": continuity_ok,
        "coverage_gap_detected": bool(valid_roots) and len(successor_roots) < minimum_successor_count,
        "valid_root_count": len(valid_roots),
        "expired_root_count": len(expired_roots),
        "bundle_root_count": len(roots),
        "minimum_successor_count": minimum_successor_count,
        "minimum_overlap_hours": minimum_overlap_hours,
        "errors": errors,
        "keys_observed": sorted(key_fps),
        "roots": root_rows,
    }


def write_metrics(path: Path, result: dict[str, Any]) -> None:
    successor_generation_failures = 0 if result.get("continuity_ok") else 1
    lines = [
        "# HELP threadforge_trust_successor_generation_total Total generated successor trust roots by ThreadForge. Always zero; SPIRE owns generation.",
        "# TYPE threadforge_trust_successor_generation_total counter",
        "threadforge_trust_successor_generation_total 0",
        "# HELP threadforge_trust_successor_generation_failures_total Total failed successor validation/provisioning observations.",
        "# TYPE threadforge_trust_successor_generation_failures_total counter",
        f"threadforge_trust_successor_generation_failures_total {successor_generation_failures}",
        "# HELP threadforge_trust_successor_age_hours Age of selected SPIRE successor root in hours.",
        "# TYPE threadforge_trust_successor_age_hours gauge",
        "threadforge_trust_successor_age_hours nan",
        "# HELP threadforge_trust_next_root_expiry_hours Hours until active SPIRE root expiration.",
        "# TYPE threadforge_trust_next_root_expiry_hours gauge",
        "threadforge_trust_next_root_expiry_hours nan",
        "# HELP threadforge_trust_bundle_root_count Number of roots in authoritative SPIRE bundle.",
        "# TYPE threadforge_trust_bundle_root_count gauge",
        f"threadforge_trust_bundle_root_count {result.get('bundle_root_count', 0)}",
        "",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-file", required=True)
    parser.add_argument("--keys-file", required=True)
    parser.add_argument("--out-json", default="artifacts/trust/successor_root_validation.json")
    parser.add_argument("--out-metrics", default="artifacts/trust/successor_root_metrics.prom")
    parser.add_argument("--minimum-successor-count", type=int, default=int(os.getenv("TRUST_MINIMUM_SUCCESSOR_COUNT", "1")))
    parser.add_argument("--minimum-overlap-hours", type=float, default=float(os.getenv("TRUST_MINIMUM_OVERLAP_HOURS", "12")))
    args = parser.parse_args(argv)

    result = validate(
        Path(args.bundle_file).read_text(encoding="utf-8"),
        Path(args.keys_file),
        args.minimum_successor_count,
        args.minimum_overlap_hours,
    )
    out_json = Path(args.out_json)
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_metrics(Path(args.out_metrics), result)
    return 0 if result["continuity_ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
