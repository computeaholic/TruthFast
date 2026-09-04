#!/usr/bin/env python3
"""Generate artifacts/system_validation_index.json from trust matrix + live cluster state.

This script intentionally derives outputs from real inputs:
- artifacts/service_trust_matrix.json (declared identity/trust graph)
- artifacts/identity_validation_reasons.json (violations from validate_identity_graph.py)
- live Kubernetes services and AuthorizationPolicies

It does not stub outputs when inputs are absent.

Output format (dict):
    {
        "services": [{service, namespace, validated, source}],
        "s2s_enforcement_present": bool,
        "verify_status": "PASS" | "FAIL",
        "edge_violations": [...],
        "advisory_reasons": [...],
    }
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

MATRIX_PATH = Path("artifacts/service_trust_matrix.json")
INDEX_PATH = Path("artifacts/system_validation_index.json")
VIOLATIONS_PATH = Path("artifacts/identity_validation_reasons.json")
VERIFY_RESULTS_PATH = Path("artifacts/verify_results.json")


def _fail(msg: str, code: int = 1) -> int:
    print(f"[FAIL] {msg}")
    return code


def run_kubectl(args: list[str]) -> dict | None:
    cmd = ["kubectl", *args]
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def has_authz_policies(namespaces: list[str]) -> bool:
    """Return True if any Istio AuthorizationPolicy exists in any of the given namespaces."""
    for ns in namespaces:
        data = run_kubectl(["get", "authorizationpolicy", "-n", ns, "-o", "json"])
        if data is None:
            continue
        if data.get("items"):
            return True
    return False


def verify_status_from_results() -> str:
    """Fail-closed: verify is PASS only when verify_results exists and has no failures."""
    if not VERIFY_RESULTS_PATH.exists():
        return "FAIL"
    try:
        data = json.loads(VERIFY_RESULTS_PATH.read_text())
    except json.JSONDecodeError:
        return "FAIL"
    summary = data.get("summary")
    if not isinstance(summary, dict):
        return "FAIL"
    total = summary.get("total")
    failures = summary.get("failures")
    if not isinstance(total, int) or not isinstance(failures, int):
        return "FAIL"
    if total < 0 or failures < 0:
        return "FAIL"
    if total <= 0:
        return "FAIL"
    return "PASS" if failures == 0 else "FAIL"


def main() -> int:
    if not MATRIX_PATH.exists():
        return _fail("missing: artifacts/service_trust_matrix.json", code=2)

    try:
        matrix = json.loads(MATRIX_PATH.read_text())
    except json.JSONDecodeError as exc:
        return _fail(f"invalid JSON in artifacts/service_trust_matrix.json: {exc}", code=2)

    services = matrix.get("services")
    if not isinstance(services, list):
        return _fail("service_trust_matrix.json missing valid 'services' list", code=2)

    # Load identity graph violations produced by validate_identity_graph.py (if present).
    edge_violations: list[dict] = []
    advisory_reasons: list[dict] = []
    if VIOLATIONS_PATH.exists():
        try:
            all_reasons = json.loads(VIOLATIONS_PATH.read_text())
            if isinstance(all_reasons, list):
                for r in all_reasons:
                    if isinstance(r, dict):
                        if r.get("type") == "UNDECLARED_PATH":
                            edge_violations.append(r)
                        elif r.get("type") == "IDENTITY_UNVERIFIED":
                            advisory_reasons.append(r)
        except json.JSONDecodeError:
            pass  # Non-fatal; proceed without violations

    svc_json = run_kubectl(["get", "svc", "-A", "-o", "json"])
    if svc_json is None:
        return _fail("failed to query live services for validation index", code=2)

    live_services: set[tuple[str, str]] = set()
    for item in svc_json.get("items", []):
        if not isinstance(item, dict):
            continue
        meta = item.get("metadata", {}) or {}
        name = meta.get("name")
        namespace = meta.get("namespace")
        if isinstance(name, str) and isinstance(namespace, str):
            live_services.add((name, namespace))

    records: list[dict] = []
    seen: set[tuple[str, str]] = set()
    service_namespaces: list[str] = []

    for svc in services:
        if not isinstance(svc, dict):
            continue
        name = svc.get("name")
        namespace = svc.get("namespace")
        if not isinstance(name, str) or not isinstance(namespace, str):
            continue
        key = (name, namespace)
        if key in seen:
            continue
        seen.add(key)
        if namespace not in service_namespaces:
            service_namespaces.append(namespace)
        records.append(
            {
                "service": name,
                "namespace": namespace,
                "validated": key in live_services,
                "source": "service_trust_matrix+live_cluster",
            }
        )

    # Report policy presence and strict verify status from verify_results.
    s2s_present = has_authz_policies(service_namespaces)
    verify_status = verify_status_from_results()

    output = {
        "services": records,
        "s2s_enforcement_present": s2s_present,
        "verify_status": verify_status,
        "edge_violations": edge_violations,
        "advisory_reasons": advisory_reasons,
    }

    INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
    INDEX_PATH.write_text(json.dumps(output, indent=2) + "\n")
    print(
        f"[PASS] wrote {INDEX_PATH} ({len(records)} services, "
        f"s2s_enforcement={s2s_present}, verify_status={verify_status}, "
        f"edge_violations={len(edge_violations)}, advisory={len(advisory_reasons)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
