#!/usr/bin/env python3
"""
Trust Root Lifecycle Guard

Reads the authoritative SPIRE bundle (PEM) and computes lifecycle state.

Outputs:
 - JSON status at artifacts/trust/root_lifecycle_status.json
 - Prometheus metrics at artifacts/trust/root_lifecycle_metrics.prom

Designed to be invoked by verification hooks or a reconciler.

Usage examples:
  python3 scripts/trust/trust_root_lifecycle_guard.py --bundle-file /tmp/spire_bundle.pem

If --bundle-file is omitted the script will attempt to read from
the spire-server admin socket via kubectl exec (same pattern as other
scripts in this repo).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shlex
import ssl
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


def run_cmd(cmd: list[str]) -> tuple[int, str, str]:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = proc.communicate()
    return proc.returncode, out or "", err or ""


def run_cmd_bytes(cmd: list[str], input_bytes: bytes | None = None) -> tuple[int, bytes, bytes]:
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = proc.communicate(input=input_bytes)
    return proc.returncode, out or b"", err or b""


def extract_pems(bundle_text: str) -> list[str]:
    pattern = re.compile(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----")
    return pattern.findall(bundle_text or "")


def write_temp_pem(pem: str) -> str:
    fh = tempfile.NamedTemporaryFile(delete=False, suffix=".pem")
    fh.write(pem.encode("utf-8"))
    fh.flush()
    fh.close()
    return fh.name


def openssl_field(pem_path: str, args: list[str]) -> str:
    cmd = ["openssl", "x509", "-in", pem_path, "-noout"] + args
    rc, out, err = run_cmd(cmd)
    if rc != 0:
        raise RuntimeError(f"openssl failed: {' '.join(cmd)}\n{err}")
    return out.strip()


def parse_x509(pem: str) -> dict:
    path = write_temp_pem(pem)
    try:
        serial = openssl_field(path, ["-serial"])  # e.g. serial=...
        subject = openssl_field(path, ["-subject"])  # e.g. subject=...
        issuer = openssl_field(path, ["-issuer"])  # e.g. issuer=...
        # start/end
        start = openssl_field(path, ["-startdate"])  # notBefore=...
        end = openssl_field(path, ["-enddate"])  # notAfter=...
        # full text to extract SKI/AKI
        rc, text, err = run_cmd(["openssl", "x509", "-in", path, "-noout", "-text"])
        if rc != 0:
            raise RuntimeError(f"openssl text failed: {err}")
        ski = ""
        aki = ""
        # parse X509v3 extensions
        m_ski = re.search(r"Subject Key Identifier:\s*([0-9A-Fa-f:\s]+)", text)
        if m_ski:
            ski = m_ski.group(1).replace(":", "").replace(" ", "").lower()
        m_aki = re.search(r"Authority Key Identifier:\s*\n\s*keyid: ([0-9A-Fa-f:\s]+)", text)
        if m_aki:
            aki = m_aki.group(1).replace(":", "").replace(" ", "").lower()
        der = ssl.PEM_cert_to_DER_cert(pem)

        # normalize outputs
        serial_value = serial.split("=", 1)[1] if "=" in serial else serial
        subject_value = subject.split("=", 1)[1] if "=" in subject else subject
        issuer_value = issuer.split("=", 1)[1] if "=" in issuer else issuer
        not_before = start.split("=", 1)[1] if "=" in start else start
        not_after = end.split("=", 1)[1] if "=" in end else end

        return {
            "serial": serial_value.strip().lower(),
            "subject": subject_value.strip(),
            "issuer": issuer_value.strip(),
            "ski": ski,
            "aki": aki,
            "fingerprint_sha256": hashlib.sha256(der).hexdigest(),
            "public_key_sha256": public_key_sha256_from_cert(path),
            "not_before": not_before.strip(),
            "not_after": not_after.strip(),
            "pem": pem,
        }
    finally:
        try:
            os.unlink(path)
        except Exception:
            pass


def public_key_sha256_from_cert(pem_path: str) -> str:
    rc, pub, err = run_cmd(["openssl", "x509", "-in", pem_path, "-pubkey", "-noout"])
    if rc != 0:
        raise RuntimeError(f"openssl public key extraction failed: {err}")
    rc, der, err_bytes = run_cmd_bytes(
        ["openssl", "pkey", "-pubin", "-in", "/dev/stdin", "-pubout", "-outform", "DER"],
        pub.encode("utf-8"),
    )
    if rc != 0:
        raise RuntimeError(f"openssl public key normalization failed: {err_bytes.decode('utf-8', errors='replace')}")
    return hashlib.sha256(der).hexdigest()


def parse_openssl_time(value: str) -> datetime:
    # Accept formats produced by openssl x509 -startdate/-enddate
    # Example: "notAfter=May 30 04:16:01 2026 GMT"
    v = value.strip()
    if v.startswith("notBefore=") or v.startswith("notAfter="):
        v = v.split("=", 1)[1].strip()
    # try formats
    fmts = ["%b %d %H:%M:%S %Y %Z", "%Y%m%d%H%M%SZ", "%Y-%m-%dT%H:%M:%S%z"]
    for f in fmts:
        try:
            return datetime.strptime(v, f).replace(tzinfo=timezone.utc)
        except Exception:
            continue
    # last resort: try fromisoformat
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00")).astimezone(timezone.utc)
    except Exception:
        raise RuntimeError(f"unable to parse openssl time: {value}")


def normalize_serial(value: object) -> str:
    return str(value or "").replace(":", "").strip().lower()


def load_json_file(path: str | None) -> dict:
    if not path:
        return {}
    p = Path(path)
    if not p.exists():
        raise RuntimeError(f"missing JSON input file: {path}")
    return json.loads(p.read_text(encoding="utf-8"))


def load_spire_key_fingerprints(path: str | None) -> set[str]:
    if not path:
        return set()
    data = load_json_file(path)
    key_fingerprints: set[str] = set()
    for value in (data.get("keys") or {}).values():
        try:
            der = base64.b64decode(str(value))
        except Exception:
            continue
        with tempfile.NamedTemporaryFile(delete=False, suffix=".der") as fh:
            fh.write(der)
            key_path = fh.name
        try:
            rc, pub, _ = run_cmd_bytes(["openssl", "pkey", "-inform", "DER", "-in", key_path, "-pubout", "-outform", "DER"])
            if rc == 0:
                key_fingerprints.add(hashlib.sha256(pub).hexdigest())
        finally:
            try:
                os.unlink(key_path)
            except Exception:
                pass
    return key_fingerprints


def normalize_authority_row(row: dict, fallback_state: str = "") -> dict:
    state = str(row.get("state") or row.get("status") or row.get("lifecycle_state") or fallback_state).upper()
    return {
        "state": state,
        "authority_id": str(row.get("authority_id") or row.get("id") or ""),
        "serial": normalize_serial(row.get("serial")),
        "not_before": row.get("not_before") or row.get("not_before_iso"),
        "not_after": row.get("not_after") or row.get("not_after_iso"),
        "public_key_sha256": str(row.get("public_key_sha256") or row.get("key_fingerprint_sha256") or ""),
        "key_present": row.get("key_present"),
    }


def normalize_spire_authority_state(payload: dict) -> dict[str, list[dict]]:
    rows: list[dict] = []
    for key in ("authorities", "x509_authorities", "x509Authorities"):
        value = payload.get(key)
        if isinstance(value, list):
            rows.extend(normalize_authority_row(row) for row in value if isinstance(row, dict))

    for state, keys in {
        "ACTIVE": ("active", "active_authority", "active_authorities"),
        "PREPARED": ("prepared", "prepared_authority", "prepared_authorities"),
        "OLD": ("old", "old_authorities"),
    }.items():
        for key in keys:
            value = payload.get(key)
            if isinstance(value, dict):
                rows.append(normalize_authority_row(value, state))
            elif isinstance(value, list):
                rows.extend(normalize_authority_row(row, state) for row in value if isinstance(row, dict))

    deduped: list[dict] = []
    seen: set[tuple[str, str, str, str, str, str]] = set()
    for row in rows:
        key = (
            row["state"],
            row["authority_id"],
            row["serial"],
            str(row.get("not_before") or ""),
            str(row.get("not_after") or ""),
            row["public_key_sha256"],
        )
        if key in seen:
            continue
        seen.add(key)
        deduped.append(row)

    grouped = {"ACTIVE": [], "PREPARED": [], "OLD": []}
    for row in deduped:
        if row["state"] in grouped:
            grouped[row["state"]].append(row)
    return grouped


def build_spire_native_lifecycle(
    roots: list[dict],
    authority_payload: dict | None,
    key_fingerprints: set[str],
    now: datetime | None = None,
) -> dict:
    if authority_payload is None:
        return {
            "source": "not_supplied",
            "active_authority_state": [],
            "prepared_authority_state": [],
            "old_authority_state": [],
            "active_authorities": [],
            "prepared_authorities": [],
            "old_authorities": [],
            "prepared_exists": False,
            "prepared_published": None,
            "prepared_key_present": None,
            "overlap_duration_hours": None,
            "overlap_exists": False,
            "extends_active": None,
            "prepare_due": None,
            "activate_due": None,
            "prepare_threshold_time": None,
            "activate_threshold_time": None,
            "valid_prepared_successor_count": 0,
        }

    grouped = normalize_spire_authority_state(authority_payload)
    root_serials = {normalize_serial(root.get("serial")) for root in roots}
    roots_by_serial = {normalize_serial(root.get("serial")): root for root in roots if normalize_serial(root.get("serial"))}
    active = [enrich_authority_row(row, roots_by_serial, roots) for row in grouped["ACTIVE"]]
    prepared = grouped["PREPARED"]
    old = [
        row
        for row in (enrich_authority_row(candidate, roots_by_serial, roots) for candidate in grouped["OLD"])
        if normalize_serial(row.get("serial"))
    ]

    active_not_after = None
    active_not_before = None
    if active:
        active_nb_values = [parse_openssl_time(row["not_before"]) for row in active if row.get("not_before")]
        active_na_values = [parse_openssl_time(row["not_after"]) for row in active if row.get("not_after")]
        if active_nb_values:
            active_not_before = min(active_nb_values)
        if active_na_values:
            active_not_after = max(active_na_values)

    prepare_threshold_time = None
    activate_threshold_time = None
    prepare_due = None
    activate_due = None
    if active_not_before is not None and active_not_after is not None:
        lifetime = active_not_after - active_not_before
        prepare_threshold_time = active_not_after - min(lifetime / 2, timedelta(days=30))
        activate_threshold_time = active_not_after - min(lifetime / 6, timedelta(days=7))
        current_time = now or datetime.now(timezone.utc)
        prepare_due = current_time >= prepare_threshold_time
        activate_due = current_time >= activate_threshold_time

    prepared_rows = []
    overlap_hours: list[float] = []
    extends_active_values: list[bool] = []
    prepared_published_values: list[bool] = []
    prepared_key_values: list[bool | None] = []
    valid_prepared_successor_count = 0
    for row in prepared:
        serial = normalize_serial(row.get("serial"))
        root = find_matching_root(row, roots_by_serial, roots)
        row = dict(row)
        if not serial and root.get("serial"):
            serial = normalize_serial(root.get("serial"))
            row["serial"] = serial
        row["published_in_bundle"] = bool(serial and serial in root_serials)
        prepared_published_values.append(row["published_in_bundle"])
        nb_value = row.get("not_before") or root.get("not_before")
        na_value = row.get("not_after") or root.get("not_after")
        row_overlap_hours = None
        if active_not_after is not None and nb_value:
            row_overlap_hours = round((active_not_after - parse_openssl_time(str(nb_value))).total_seconds() / 3600.0, 3)
            row["overlap_duration_hours"] = row_overlap_hours
            overlap_hours.append(row_overlap_hours)
        if active_not_after is not None and na_value:
            extends = parse_openssl_time(str(na_value)) > active_not_after
            row["extends_active"] = extends
            extends_active_values.append(extends)
        key_present = row.get("key_present")
        public_key_sha256 = row.get("public_key_sha256") or root.get("public_key_sha256") or ""
        if key_present is None and key_fingerprints and public_key_sha256:
            key_present = public_key_sha256 in key_fingerprints
        row["key_present"] = key_present
        prepared_key_values.append(key_present if isinstance(key_present, bool) else None)
        if row["published_in_bundle"] and key_present is True and (row_overlap_hours or 0) > 0 and row.get("extends_active") is True:
            valid_prepared_successor_count += 1
        prepared_rows.append(row)

    overlap_exists = any(value > 0 for value in overlap_hours)
    return {
        "source": authority_payload.get("source", "spire-authority-state-file"),
        "active_authority_state": active,
        "prepared_authority_state": prepared_rows,
        "old_authority_state": old,
        "active_authorities": active,
        "prepared_authorities": prepared_rows,
        "old_authorities": old,
        "prepared_exists": bool(prepared_rows),
        "prepared_published": any(prepared_published_values) if prepared_published_values else False,
        "prepared_key_present": (
            any(value is True for value in prepared_key_values)
            if any(value is not None for value in prepared_key_values)
            else None
        ),
        "overlap_duration_hours": min(overlap_hours) if overlap_hours else None,
        "overlap_exists": overlap_exists,
        "extends_active": any(extends_active_values) if extends_active_values else False,
        "prepare_due": prepare_due,
        "activate_due": activate_due,
        "prepare_threshold_time": prepare_threshold_time.isoformat().replace("+00:00", "Z")
        if prepare_threshold_time is not None
        else None,
        "activate_threshold_time": activate_threshold_time.isoformat().replace("+00:00", "Z")
        if activate_threshold_time is not None
        else None,
        "valid_prepared_successor_count": valid_prepared_successor_count,
    }


def enrich_authority_row(row: dict, roots_by_serial: dict[str, dict], roots: list[dict]) -> dict:
    root = find_matching_root(row, roots_by_serial, roots)
    enriched = dict(row)
    if root.get("serial") and not normalize_serial(enriched.get("serial")):
        enriched["serial"] = normalize_serial(root.get("serial"))
    if root.get("not_before") and not enriched.get("not_before"):
        enriched["not_before"] = root.get("not_before")
    if root.get("not_after") and not enriched.get("not_after"):
        enriched["not_after"] = root.get("not_after")
    if root.get("public_key_sha256") and not enriched.get("public_key_sha256"):
        enriched["public_key_sha256"] = root.get("public_key_sha256")
    return enriched


def find_matching_root(row: dict, roots_by_serial: dict[str, dict], roots: list[dict]) -> dict:
    serial = normalize_serial(row.get("serial"))
    if serial and serial in roots_by_serial:
        return roots_by_serial[serial]

    row_nb = parse_optional_time(row.get("not_before"))
    row_na = parse_optional_time(row.get("not_after"))
    if row_na is None:
        return {}

    for root in roots:
        root_na = parse_optional_time(root.get("not_after"))
        if root_na != row_na:
            continue
        if row_nb is None:
            return root
        root_nb = parse_optional_time(root.get("not_before"))
        if root_nb == row_nb:
            return root
    return {}


def parse_optional_time(value: object) -> datetime | None:
    if not value:
        return None
    try:
        return parse_openssl_time(str(value))
    except Exception:
        return None


def apply_spire_native_decisions(status: dict, spire_native: dict) -> dict:
    continuous_policy_predicates = {
        "prepared_exists": bool(spire_native.get("prepared_exists") or spire_native.get("prepared_authority_state")),
        "prepared_published": spire_native.get("prepared_published") is True,
        "prepared_key_present": spire_native.get("prepared_key_present") is True,
        "overlap_exists": spire_native.get("overlap_exists") is True
        or (spire_native.get("overlap_duration_hours") is not None and spire_native.get("overlap_duration_hours") > 0),
        "extends_active": spire_native.get("extends_active") is True,
    }
    continuous_successor_policy_ok = all(continuous_policy_predicates.values())
    successor_count = int(spire_native.get("valid_prepared_successor_count") or 0)
    if continuous_successor_policy_ok and successor_count == 0:
        successor_count = 1

    prepare_due = bool(spire_native.get("prepare_due"))
    activate_due = bool(spire_native.get("activate_due"))
    active_exists = bool(spire_native.get("active_authority_state"))
    spire_lifecycle_predicates = {
        "active_exists": active_exists,
        "prepare_due": prepare_due,
        "activate_due": activate_due,
        "prepared_exists_when_required": (not prepare_due) or continuous_policy_predicates["prepared_exists"],
        "prepared_published_when_required": (not prepare_due) or continuous_policy_predicates["prepared_published"],
        "prepared_key_present_when_required": (not prepare_due) or continuous_policy_predicates["prepared_key_present"],
        "overlap_exists_when_required": (not prepare_due) or continuous_policy_predicates["overlap_exists"],
        "extends_active_when_required": (not prepare_due) or continuous_policy_predicates["extends_active"],
    }
    spire_lifecycle_ok = active_exists and all(
        value
        for key, value in spire_lifecycle_predicates.items()
        if key not in {"prepare_due", "activate_due"}
    )

    if not active_exists:
        continuity_state = "VIOLATION"
    elif spire_lifecycle_ok and prepare_due and continuous_successor_policy_ok and activate_due:
        continuity_state = "ROTATING"
    elif spire_lifecycle_ok and prepare_due and continuous_successor_policy_ok:
        continuity_state = "ACTIVE_PLUS_PREPARED"
    elif spire_lifecycle_ok and not prepare_due:
        continuity_state = "ACTIVE_ONLY"
    elif prepare_due:
        continuity_state = "PREPARE_DUE"
    else:
        continuity_state = "VIOLATION"

    status["legacy_bundle_successor_model"] = {
        "successor_count": status.get("successor_count", 0),
        "continuity_ok": status.get("continuity_ok", False),
        "coverage_gap_detected": status.get("coverage_gap_detected", True),
        "future_root_count": status.get("future_root_count", 0),
    }
    status["continuity_model"] = "spire_native_lifecycle"
    status["spire_native_lifecycle"] = spire_native
    status["spire_native_continuity_predicates"] = continuous_policy_predicates
    status["continuous_successor_policy_ok"] = continuous_successor_policy_ok
    status["continuous_successor_gap_detected"] = not continuous_successor_policy_ok
    status["spire_lifecycle_ok"] = spire_lifecycle_ok
    status["spire_lifecycle_predicates"] = spire_lifecycle_predicates
    status["prepare_due"] = prepare_due
    status["activate_due"] = activate_due
    status["continuity_state"] = continuity_state
    active_authorities = spire_native.get("active_authority_state") or []
    if active_authorities:
        active_serial = normalize_serial(active_authorities[0].get("serial"))
        if active_serial:
            status["active_root_serial"] = active_serial
    status["successor_count"] = successor_count
    status["future_root_count"] = successor_count
    status["coverage_gap_detected"] = not continuous_successor_policy_ok
    status["continuity_ok"] = continuous_successor_policy_ok
    return status


def compute_state(roots: list[dict], now: datetime, warning_hours: float, critical_hours: float, emergency_hours: float) -> dict:
    # classify each root
    for r in roots:
        nb = parse_openssl_time(r["not_before"]) if r.get("not_before") else None
        na = parse_openssl_time(r["not_after"]) if r.get("not_after") else None
        # store ISO strings for JSON serialization
        r["not_before_iso"] = nb.isoformat() if nb is not None else None
        r["not_after_iso"] = na.isoformat() if na is not None else None
        r["expired"] = (na is not None and na < now)
        r["currently_valid"] = (nb is not None and na is not None and (nb <= now <= na))
        r["future_valid"] = (nb is not None and nb > now)

    valid_roots = [r for r in roots if r["currently_valid"]]
    expired_roots = [r for r in roots if r["expired"]]

    valid_root_count = len(valid_roots)

    hours_until_last_valid_expires = None
    successor_count = 0
    successor_serials = set()
    active_root = None
    if valid_roots:
        active_root = max(
            valid_roots,
            key=lambda r: parse_openssl_time(r["not_before"]) if r.get("not_before") else datetime.min.replace(tzinfo=timezone.utc),
        )
        # Determine last valid root expiration (latest notAfter among current valids)
        last = max(parse_openssl_time(r["not_after"]) for r in valid_roots if r.get("not_after"))
        delta = last - now
        hours_until_last_valid_expires = delta.total_seconds() / 3600.0

        # Legacy diagnostic model only. Continuity decisions are replaced later
        # by apply_spire_native_decisions() using SPIRE ACTIVE/PREPARED state.
        for r in roots:
            try:
                nb = parse_openssl_time(r["not_before"]) if r.get("not_before") else None
                na = parse_openssl_time(r["not_after"]) if r.get("not_after") else None
            except Exception:
                continue
            if nb is None or na is None:
                continue
            # Legacy bundle-horizon successor definition retained only for
            # before/after evidence in legacy_bundle_successor_model.
            if nb <= last and na > last:
                successor_count += 1
                successor_serials.add(str(r.get("serial", "")).lower())

    for r in roots:
        if r.get("parse_error"):
            r["lifecycle_state"] = "UNKNOWN"
            continue
        serial = str(r.get("serial", "")).lower()
        if r.get("expired"):
            r["lifecycle_state"] = "EXPIRED"
        elif active_root is not None and serial == str(active_root.get("serial", "")).lower():
            r["lifecycle_state"] = "ACTIVE"
        elif serial in successor_serials:
            r["lifecycle_state"] = "SUCCESSOR"
        elif r.get("future_valid"):
            r["lifecycle_state"] = "FUTURE"
        else:
            r["lifecycle_state"] = "FUTURE"

    # Determine state **ONLY** based on time/validity (DO NOT consider successor availability)
    # EXHAUSTED: valid_root_count == 0
    # CRITICAL: valid_root_count > 0 AND hours_until_last_valid_expires <= critical/emergency thresholds
    # WARNING: valid_root_count > 0 AND critical_hours < hours_until_last_valid_expires <= warning_hours
    # HEALTHY: valid_root_count > 0 AND hours_until_last_valid_expires > warning_hours
    state = "unknown"
    if valid_root_count == 0:
        state = "exhausted"
    else:
        if hours_until_last_valid_expires is not None and hours_until_last_valid_expires <= emergency_hours:
            state = "critical"
        elif hours_until_last_valid_expires is not None and hours_until_last_valid_expires <= critical_hours:
            state = "critical"
        elif hours_until_last_valid_expires is not None and hours_until_last_valid_expires <= warning_hours:
            state = "warning"
        else:
            state = "healthy"

    # compatibility: keep future_root_count but also expose successor_count explicitly
    future_root_count = successor_count

    # coverage gap and continuity semantics
    coverage_gap_detected = (valid_root_count > 0) and (successor_count == 0)
    # continuity_ok true only when there is a currently valid root and no coverage gap
    continuity_ok = (valid_root_count > 0) and (not coverage_gap_detected)

    return {
        "valid_root_count": valid_root_count,
        "future_root_count": future_root_count,
        "successor_count": successor_count,
        "minimum_successor_count": 1,
        "minimum_overlap_hours": 12,
        "maximum_rotation_interval_hours": 720,
        "active_root_serial": active_root.get("serial", "") if active_root else "",
        "expired_root_count": len(expired_roots),
        "hours_until_last_valid_expires": None if hours_until_last_valid_expires is None else round(hours_until_last_valid_expires, 3),
        "state": state,
        "coverage_gap_detected": coverage_gap_detected,
        "continuity_ok": continuity_ok,
        "roots": roots,
    }


def write_json_status(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_prom_metrics(path: Path, status: dict) -> None:
    # Numeric mapping for state
    state_map = {"healthy": 0, "warning": 1, "critical": 2, "exhausted": 3}
    s = []
    s.append('# HELP threadforge_trust_valid_root_count Number of currently valid roots in SPIRE bundle')
    s.append('# TYPE threadforge_trust_valid_root_count gauge')
    s.append(f'threadforge_trust_valid_root_count {status["valid_root_count"]}')
    s.append('# HELP threadforge_trust_future_root_count Compatibility alias for SPIRE-native successor_count')
    s.append('# TYPE threadforge_trust_future_root_count gauge')
    s.append(f'threadforge_trust_future_root_count {status["future_root_count"]}')
    s.append('# HELP threadforge_trust_successor_count Number of SPIRE PREPARED authorities satisfying continuity predicates')
    s.append('# TYPE threadforge_trust_successor_count gauge')
    s.append(f'threadforge_trust_successor_count {status["successor_count"]}')
    s.append('# HELP threadforge_trust_root_hours_remaining Hours until the last currently valid root expires (float hours)')
    s.append('# TYPE threadforge_trust_root_hours_remaining gauge')
    hrs = status.get("hours_until_last_valid_expires")
    hrs_val = "nan" if hrs is None else f"{hrs}"
    s.append(f'threadforge_trust_root_hours_remaining {hrs_val}')
    s.append('# HELP threadforge_trust_root_lifecycle_state Numeric lifecycle state: 0=healthy,1=warning,2=critical,3=exhausted')
    s.append('# TYPE threadforge_trust_root_lifecycle_state gauge')
    s.append(f'threadforge_trust_root_lifecycle_state {state_map.get(status.get("state","unknown"), -1)}')
    s.append('# HELP threadforge_trust_continuity_ok Trust root continuity compliance: 1=continuous,0=not continuous')
    s.append('# TYPE threadforge_trust_continuity_ok gauge')
    s.append(f'threadforge_trust_continuity_ok {1 if status.get("continuity_ok") else 0}')
    s.append('# HELP threadforge_trust_coverage_gap_detected Trust root coverage gap detected: 1=gap,0=no gap')
    s.append('# TYPE threadforge_trust_coverage_gap_detected gauge')
    s.append(f'threadforge_trust_coverage_gap_detected {1 if status.get("coverage_gap_detected") else 0}')
    s.append('# HELP threadforge_trust_spire_lifecycle_ok SPIRE lifecycle contract health: 1=healthy,0=violation')
    s.append('# TYPE threadforge_trust_spire_lifecycle_ok gauge')
    s.append(f'threadforge_trust_spire_lifecycle_ok {1 if status.get("spire_lifecycle_ok") else 0}')
    s.append('# HELP threadforge_trust_continuous_successor_policy_ok ThreadForge continuous successor policy: 1=satisfied,0=unsatisfied')
    s.append('# TYPE threadforge_trust_continuous_successor_policy_ok gauge')
    s.append(f'threadforge_trust_continuous_successor_policy_ok {1 if status.get("continuous_successor_policy_ok") else 0}')
    s.append('# HELP threadforge_trust_continuous_successor_gap_detected ThreadForge continuous successor policy gap: 1=gap,0=no gap')
    s.append('# TYPE threadforge_trust_continuous_successor_gap_detected gauge')
    s.append(f'threadforge_trust_continuous_successor_gap_detected {1 if status.get("continuous_successor_gap_detected") else 0}')
    s.append('# HELP threadforge_trust_prepare_due SPIRE successor preparation is currently due: 1=yes,0=no,-1=unknown')
    s.append('# TYPE threadforge_trust_prepare_due gauge')
    s.append(f'threadforge_trust_prepare_due {bool_metric(status.get("prepare_due"))}')
    s.append('# HELP threadforge_trust_activate_due SPIRE prepared authority activation is currently due: 1=yes,0=no,-1=unknown')
    s.append('# TYPE threadforge_trust_activate_due gauge')
    s.append(f'threadforge_trust_activate_due {bool_metric(status.get("activate_due"))}')
    spire_native = status.get("spire_native_lifecycle") or {}
    active_present = 1 if spire_native.get("active_authority_state") else 0
    prepared_present = 1 if spire_native.get("prepared_authority_state") else 0
    old_count = len(spire_native.get("old_authority_state") or [])
    prepared_published = spire_native.get("prepared_published")
    prepared_key_present = spire_native.get("prepared_key_present")
    extends_active = spire_native.get("extends_active")
    overlap_duration_hours = spire_native.get("overlap_duration_hours")
    s.append('# HELP threadforge_trust_spire_active_authority_present SPIRE-native ACTIVE authority state observed: 1=yes,0=no')
    s.append('# TYPE threadforge_trust_spire_active_authority_present gauge')
    s.append(f'threadforge_trust_spire_active_authority_present {active_present}')
    s.append('# HELP threadforge_trust_spire_prepared_authority_present SPIRE-native PREPARED authority state observed: 1=yes,0=no')
    s.append('# TYPE threadforge_trust_spire_prepared_authority_present gauge')
    s.append(f'threadforge_trust_spire_prepared_authority_present {prepared_present}')
    s.append('# HELP threadforge_trust_spire_old_authority_count SPIRE-native OLD authority states observed')
    s.append('# TYPE threadforge_trust_spire_old_authority_count gauge')
    s.append(f'threadforge_trust_spire_old_authority_count {old_count}')
    s.append('# HELP threadforge_trust_spire_prepared_published SPIRE PREPARED authority is published in the authoritative bundle: 1=yes,0=no,-1=unknown')
    s.append('# TYPE threadforge_trust_spire_prepared_published gauge')
    s.append(f'threadforge_trust_spire_prepared_published {bool_metric(prepared_published)}')
    s.append('# HELP threadforge_trust_spire_prepared_key_present SPIRE PREPARED authority private key is present: 1=yes,0=no,-1=unknown')
    s.append('# TYPE threadforge_trust_spire_prepared_key_present gauge')
    s.append(f'threadforge_trust_spire_prepared_key_present {bool_metric(prepared_key_present)}')
    s.append('# HELP threadforge_trust_spire_prepared_overlap_duration_hours Overlap hours between SPIRE ACTIVE expiry and PREPARED notBefore')
    s.append('# TYPE threadforge_trust_spire_prepared_overlap_duration_hours gauge')
    s.append(f'threadforge_trust_spire_prepared_overlap_duration_hours {number_metric(overlap_duration_hours)}')
    s.append('# HELP threadforge_trust_spire_prepared_extends_active SPIRE PREPARED authority notAfter extends ACTIVE notAfter: 1=yes,0=no,-1=unknown')
    s.append('# TYPE threadforge_trust_spire_prepared_extends_active gauge')
    s.append(f'threadforge_trust_spire_prepared_extends_active {bool_metric(extends_active)}')

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(s) + "\n", encoding="utf-8")


def bool_metric(value: object) -> int:
    if value is None:
        return -1
    return 1 if value is True else 0


def number_metric(value: object) -> str:
    if value is None:
        return "nan"
    return str(value)


def fetch_bundle_via_kubectl(tmp_path: str) -> str:
    # attempt to get spire-server pod name
    # prefer spire-server-0 as used elsewhere
    cmd = ["kubectl", "-n", "spire-system", "exec", "spire-server-0", "--", "/opt/spire/bin/spire-server", "bundle", "show", "-socketPath", "/run/spire/private/spire-server.sock", "-format", "pem"]
    rc, out, err = run_cmd(cmd)
    if rc != 0 or not out.strip():
        # fall back to kubectl get configmap spire-ca-root-cert (not primary but helpful)
        cmd2 = ["kubectl", "-n", "spire-system", "get", "configmap", "spire-ca-root-cert", "-o", "jsonpath={.data.root-cert\\.pem}"]
        rc2, out2, err2 = run_cmd(cmd2)
        if rc2 != 0:
            raise RuntimeError(f"unable to read SPIRE bundle via kubectl: {err}\n{err2}")
        out = out2
    Path(tmp_path).write_text(out, encoding="utf-8")
    return out


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--bundle-file", help="Path to SPIRE bundle PEM file. If omitted the script will attempt to read from spire-server via kubectl.")
    p.add_argument("--out-json", default="artifacts/trust/root_lifecycle_status.json")
    p.add_argument("--out-metrics", default="artifacts/trust/root_lifecycle_metrics.prom")
    p.add_argument("--warning-hours", type=float, default=float(os.getenv("ROOT_WARNING_HOURS", "24")))
    p.add_argument("--critical-hours", type=float, default=float(os.getenv("ROOT_CRITICAL_HOURS", "6")))
    p.add_argument("--emergency-hours", type=float, default=float(os.getenv("ROOT_EMERGENCY_HOURS", "1")))
    p.add_argument("--spire-authority-state-file", help="Optional SPIRE LocalAuthority/journal-derived X.509 authority state JSON.")
    p.add_argument("--spire-keys-file", help="Optional SPIRE disk KeyManager keys.json for prepared_key_present evidence.")
    args = p.parse_args(argv)

    if args.bundle_file:
        bundle_text = Path(args.bundle_file).read_text(encoding="utf-8")
    else:
        tmp = tempfile.mktemp(prefix="spire_bundle_")
        bundle_text = fetch_bundle_via_kubectl(tmp)

    pems = extract_pems(bundle_text)
    roots = []
    for pem in pems:
        try:
            roots.append(parse_x509(pem))
        except Exception as e:
            # skip malformed certs but record error
            roots.append({"pem": pem, "parse_error": str(e)})

    now = datetime.now(timezone.utc)
    status = compute_state(roots, now, args.warning_hours, args.critical_hours, args.emergency_hours)
    authority_payload = load_json_file(args.spire_authority_state_file) if args.spire_authority_state_file else None
    key_fingerprints = load_spire_key_fingerprints(args.spire_keys_file)
    spire_native = build_spire_native_lifecycle(roots, authority_payload, key_fingerprints, now=now)
    status = apply_spire_native_decisions(status, spire_native)

    write_json_status(Path(args.out_json), status)
    write_prom_metrics(Path(args.out_metrics), status)

    # exit codes: 0 normal, 2 exhausted or warning/critical that should fail proof? We'll not enforce here.
    # Caller (verify script) decides which states should cause proof failure.
    return 0


if __name__ == "__main__":
    try:
        rc = main(sys.argv[1:])
        sys.exit(rc)
    except Exception as e:
        print(f"[error] trust_root_lifecycle_guard: {e}", file=sys.stderr)
        sys.exit(3)
