#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

MATRIX_PATH = Path("artifacts/service_trust_matrix.json")
VIOLATIONS_PATH = Path("artifacts/identity_validation_reasons.json")


def run_kubectl(args: list[str]) -> dict | None:
    """Run kubectl command; return parsed JSON dict or None on any error."""
    try:
        out = subprocess.check_output(["kubectl", *args], text=True, stderr=subprocess.PIPE)
        return json.loads(out)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def load_matrix() -> dict:
    if not MATRIX_PATH.exists():
        print(f"❌ Expected matrix not found: {MATRIX_PATH}")
        sys.exit(2)
    return json.loads(MATRIX_PATH.read_text())


def check_service_ready(name: str, namespace: str) -> list[dict]:
    """Return SERVICE_NOT_READY reasons if service has no ready endpoints or running pods."""
    # Check endpoints — any ready address means at least one endpoint is up.
    ep = run_kubectl(["get", "endpoints", name, "-n", namespace, "-o", "json"])
    if ep is None:
        return [{"type": "SERVICE_NOT_READY", "component": name, "message": "no ready endpoints or pods"}]
    subsets = ep.get("subsets") or []
    has_ready = any(
        isinstance(s, dict) and isinstance(s.get("addresses"), list) and s.get("addresses") for s in subsets
    )
    if not has_ready:
        return [{"type": "SERVICE_NOT_READY", "component": name, "message": "no ready endpoints or pods"}]

    # Check running pods matched by app=<name> label.
    pods = run_kubectl(
        [
            "get",
            "pods",
            "-n",
            namespace,
            "-l",
            f"app={name}",
            "--field-selector=status.phase=Running",
            "-o",
            "json",
        ]
    )
    if pods is None or not pods.get("items"):
        return [{"type": "SERVICE_NOT_READY", "component": name, "message": "no ready endpoints or pods"}]
    return []


def get_authz_policy_edges(namespaces: list[str]) -> set[tuple[str, str]]:
    """Extract (from, to) edge tuples from Istio AuthorizationPolicies in given namespaces.

    Target = selector.matchLabels.app (or policy name) + "." + namespace.
    Source = last path component of SPIFFE principal (e.g. service-account name).
    Only ALLOW action policies are included.
    """
    detected: set[tuple[str, str]] = set()
    for ns in namespaces:
        data = run_kubectl(["get", "authorizationpolicy", "-n", ns, "-o", "json"])
        if data is None:
            continue
        for policy in data.get("items", []):
            if not isinstance(policy, dict):
                continue
            spec = policy.get("spec") or {}
            if spec.get("action", "ALLOW").upper() != "ALLOW":
                continue
            selector_labels = (spec.get("selector") or {}).get("matchLabels") or {}
            target_app = selector_labels.get("app") or (policy.get("metadata") or {}).get("name", "")
            target = f"{target_app}.{ns}"
            for rule in spec.get("rules") or []:
                for from_block in rule.get("from") or []:
                    for principal in (from_block.get("source") or {}).get("principals") or []:
                        parts = [p for p in principal.split("/") if p]
                        src = parts[-1] if parts else principal
                        detected.add((src, target))
    return detected


def main() -> int:
    matrix = load_matrix()
    services = matrix.get("services", [])
    edges = matrix.get("edges", [])

    if not isinstance(services, list) or not isinstance(edges, list):
        print("❌ Invalid service_trust_matrix.json format")
        return 2

    fail_reasons: list[dict] = []
    service_namespaces: set[str] = set()

    # Validate required service fields, live existence, and readiness.
    for svc in services:
        if not isinstance(svc, dict):
            fail_reasons.append(
                {
                    "type": "SYSTEM_REGRESSION",
                    "component": "unknown",
                    "message": "Service entry is not an object",
                }
            )
            continue
        name = svc.get("name")
        namespace = svc.get("namespace")
        spiffe_id = svc.get("spiffe_id")
        reachable = svc.get("reachable")

        if not isinstance(name, str) or not name:
            fail_reasons.append(
                {
                    "type": "SYSTEM_REGRESSION",
                    "component": "unknown",
                    "message": "Service entry missing valid name",
                }
            )
            continue
        if not isinstance(namespace, str) or not namespace:
            fail_reasons.append(
                {
                    "type": "SYSTEM_REGRESSION",
                    "component": name,
                    "message": "Service missing valid namespace",
                }
            )
            continue
        service_namespaces.add(namespace)

        if not isinstance(spiffe_id, str) or not spiffe_id.startswith("spiffe://"):
            fail_reasons.append(
                {
                    "type": "SYSTEM_REGRESSION",
                    "component": name,
                    "message": "Service missing valid spiffe_id",
                }
            )
        if not isinstance(reachable, bool):
            fail_reasons.append(
                {
                    "type": "SYSTEM_REGRESSION",
                    "component": name,
                    "message": "Service missing valid reachable flag",
                }
            )

        # Live service existence check.
        svc_json = run_kubectl(["get", "svc", name, "-n", namespace, "-o", "json"])
        if svc_json is None or svc_json.get("metadata", {}).get("name") != name:
            fail_reasons.append(
                {
                    "type": "SYSTEM_REGRESSION",
                    "component": name,
                    "message": f"Service mismatch in cluster: {namespace}/{name}",
                }
            )
            continue

        # Task 2: Endpoint and pod readiness (fail-closed).
        fail_reasons.extend(check_service_ready(name, namespace))

    # Declared edge set for comparison.
    declared_edges: set[tuple[str, str]] = {
        (e["from"], e["to"]) for e in edges if isinstance(e, dict) and e.get("allowed") is True
    }

    # Minimal contract: at least one allowed edge must be declared.
    if not declared_edges:
        fail_reasons.append(
            {
                "type": "SYSTEM_REGRESSION",
                "component": "trust-matrix",
                "message": "No allowed edges found",
            }
        )

    has_ingress_echo = ("ingress", "echo.threadforge-test") in declared_edges
    if not has_ingress_echo:
        fail_reasons.append(
            {
                "type": "SYSTEM_REGRESSION",
                "component": "trust-matrix",
                "message": "Missing required allowed edge ingress -> echo.threadforge-test",
            }
        )

    # Task 1: Strict edge validation — any runtime edge not declared is a FAIL.
    detected_edges = get_authz_policy_edges(list(service_namespaces))
    extra_edges = detected_edges - declared_edges
    for src, dst in sorted(extra_edges):
        fail_reasons.append(
            {
                "type": "UNDECLARED_PATH",
                "from": src,
                "to": dst,
                "message": "edge exists but not declared in trust matrix",
            }
        )

    # Write all reasons to artifact for downstream consumers.
    all_reasons = fail_reasons
    VIOLATIONS_PATH.parent.mkdir(parents=True, exist_ok=True)
    VIOLATIONS_PATH.write_text(json.dumps(all_reasons, indent=2) + "\n")

    if fail_reasons:
        print("❌ Identity drift detected:\n")
        for r in fail_reasons:
            if r.get("type") == "UNDECLARED_PATH":
                print(f"- [UNDECLARED_PATH] {r.get('from')} → {r.get('to')}: {r.get('message')}")
            else:
                print(f"- [{r.get('type', 'FAIL')}] {r.get('component', '')}: {r.get('message')}")
        return 1

    print("✅ Identity graph validated — no drift detected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
