#!/usr/bin/env python3
"""Generate artifacts/service_trust_matrix.json from live cluster state.

SPIRE cutover version:
- sources services from threadforge-test namespace
- derives service account from live workload pods (app=<service>)
- maps expected SPIFFE URI from namespace + service account
- emits an ingress -> echo edge when echo is present

Exit codes:
- 0: success
- 10: missing prereq (cluster unreachable / kubectl unavailable)
- 1: generation/format failure
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

TARGET_NAMESPACE = "threadforge-test"
OUT_PATH = Path("artifacts/service_trust_matrix.json")


def fail(msg: str, code: int) -> int:
    print(f"[FAIL] {msg}")
    return code


def run_kubectl_json(args: list[str]) -> dict:
    cmd = ["kubectl", *args]
    out = subprocess.check_output(cmd, text=True)
    return json.loads(out)


def cluster_reachable() -> bool:
    try:
        subprocess.check_output(["kubectl", "cluster-info"], stderr=subprocess.STDOUT, text=True)
        return True
    except Exception:
        return False


def service_reachable(namespace: str, name: str) -> bool:
    try:
        ep = run_kubectl_json(["get", "endpoints", name, "-n", namespace, "-o", "json"])
    except Exception:
        return False

    subsets = ep.get("subsets") or []
    if not isinstance(subsets, list):
        return False

    for subset in subsets:
        if not isinstance(subset, dict):
            continue
        addrs = subset.get("addresses") or []
        if isinstance(addrs, list) and len(addrs) > 0:
            return True
    return False


def _resolve_sa_from_deployment(namespace: str, service_name: str) -> str:
    try:
        deploys = run_kubectl_json(
            [
                "get",
                "deploy",
                "-n",
                namespace,
                "-l",
                f"app={service_name}",
                "-o",
                "json",
            ]
        )
    except Exception:
        return ""

    items = deploys.get("items")
    if not isinstance(items, list) or not items:
        return ""

    template_spec = ((items[0] or {}).get("spec") or {}).get("template") or {}
    sa = (template_spec.get("spec") or {}).get("serviceAccountName")
    if isinstance(sa, str) and sa:
        return sa
    return ""


def _resolve_sa_from_pods(namespace: str, service_name: str) -> str:
    try:
        pods = run_kubectl_json(
            [
                "get",
                "pods",
                "-n",
                namespace,
                "-l",
                f"app={service_name}",
                "-o",
                "json",
            ]
        )
    except Exception:
        return ""

    items = pods.get("items")
    if not isinstance(items, list) or not items:
        return ""

    service_accounts: set[str] = set()
    for item in items:
        if not isinstance(item, dict):
            continue
        sa = ((item.get("spec") or {}).get("serviceAccountName") or "").strip()
        if sa:
            service_accounts.add(sa)

    if len(service_accounts) == 1:
        return next(iter(service_accounts))
    return ""


def resolve_service_account(namespace: str, service_name: str) -> str:
    sa = _resolve_sa_from_deployment(namespace, service_name)
    if sa:
        return sa

    sa = _resolve_sa_from_pods(namespace, service_name)
    if sa:
        return sa

    return ""


def build_service_identity(namespace: str, service_account: str) -> str:
    trust_domain = (os.environ.get("SPIFFE_TRUST_DOMAIN") or "identity.threadforge.local").strip()
    if not trust_domain:
        raise RuntimeError("[FATAL] invalid SPIFFE_TRUST_DOMAIN")
    return f"spiffe://{trust_domain}/ns/{namespace}/sa/{service_account}"


def main() -> int:
    if not cluster_reachable():
        return fail("cluster unreachable (kubectl cluster-info failed)", 10)

    try:
        svc_json = run_kubectl_json(["get", "svc", "-n", TARGET_NAMESPACE, "-o", "json"])
    except FileNotFoundError:
        return fail("kubectl not found", 10)
    except subprocess.CalledProcessError:
        return fail(f"failed to list services in namespace {TARGET_NAMESPACE}", 1)
    except json.JSONDecodeError:
        return fail("invalid JSON from kubectl service listing", 1)

    items = svc_json.get("items")
    if not isinstance(items, list):
        return fail("unexpected service payload format", 1)

    services: list[dict] = []
    service_names: set[str] = set()

    for item in sorted(items, key=lambda i: i.get("metadata", {}).get("name", "")):
        if not isinstance(item, dict):
            continue
        metadata = item.get("metadata", {}) or {}
        name = metadata.get("name")
        namespace = metadata.get("namespace")
        if not isinstance(name, str) or not isinstance(namespace, str):
            continue
        service_names.add(name)
        service_account = resolve_service_account(namespace, name)
        if not service_account:
            return fail(f"unable to resolve service account for {namespace}/{name}", 1)
        services.append(
            {
                "name": name,
                "namespace": namespace,
                "service_account": service_account,
                "spiffe_id": build_service_identity(namespace, service_account),
                "reachable": service_reachable(namespace, name),
            }
        )

    edges: list[dict] = []
    if "echo" in service_names:
        edges.append(
            {
                "from": "ingress",
                "to": "echo.threadforge-test",
                "path": "/healthz",
                "allowed": True,
            }
        )
        # Declare the SA-level edges that Istio AuthorizationPolicies actually enforce.
        # The ingress gateway uses istio-ingressgateway-service-account.
        edges.append(
            {
                "from": "istio-ingressgateway-service-account",
                "to": "echo.threadforge-test",
                "allowed": True,
            }
        )
        edges.append(
            {
                "from": "test-client",
                "to": "echo.threadforge-test",
                "allowed": True,
            }
        )
        edges.append(
            {
                "from": "ingress",
                "to": "echo.threadforge-test",
                "path": "/admin",
                "allowed": False,
            }
        )

    payload = {
        "profile": "bootstrap",
        "services": services,
        "edges": edges,
    }

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"[PASS] wrote {OUT_PATH} ({len(services)} services, {len(edges)} edges)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
