#!/usr/bin/env python3
"""Explicit tenant model for ThreadForge.

Tenant is the Kubernetes namespace embedded in SPIFFE identity.
"""

from __future__ import annotations

import argparse
import json


class TenantIsolationError(ValueError):
    """Raised when tenant isolation rules are violated."""


# Namespaces that may legitimately access across namespaces.
EXPLICIT_CROSS_NAMESPACE_ALLOW: frozenset[str] = frozenset(
    {
        "observability",
        "istio-system",
        "spire-system",
        "threadforge-system",
    }
)


def extract_tenant_from_spiffe(spiffe_id: str) -> str:
    normalized = (spiffe_id or "").strip()
    if not normalized.startswith("spiffe://"):
        raise TenantIsolationError(f"invalid SPIFFE identity format: {spiffe_id!r}")

    marker = "/ns/"
    idx = normalized.find(marker)
    if idx < 0:
        raise TenantIsolationError(f"SPIFFE identity missing namespace segment: {normalized}")

    remainder = normalized[idx + len(marker) :]
    tenant = remainder.split("/", 1)[0].strip()
    if not tenant:
        raise TenantIsolationError(f"SPIFFE identity has empty namespace segment: {normalized}")
    return tenant


def validate_tenant_access(
    actor_spiffe_id: str,
    request_namespace: str,
    allowed_cross_namespace: set[str] | frozenset[str] | None = None,
) -> None:
    """Validate actor tenant can access request namespace.

    Fail-closed policy:
    - same namespace is allowed
    - cross namespace allowed only for explicitly allowed actor namespaces
    - anything else raises TenantIsolationError
    """
    actor_tenant = extract_tenant_from_spiffe(actor_spiffe_id)
    target_tenant = (request_namespace or "").strip()
    if not target_tenant:
        raise TenantIsolationError("request namespace is required")

    if actor_tenant == target_tenant:
        return

    allowlist = (
        EXPLICIT_CROSS_NAMESPACE_ALLOW if allowed_cross_namespace is None else frozenset(allowed_cross_namespace)
    )
    if actor_tenant in allowlist:
        return

    raise TenantIsolationError(
        f"tenant isolation violation: actor namespace {actor_tenant!r} cannot access {target_tenant!r}"
    )


def _cli() -> int:
    parser = argparse.ArgumentParser(description="Validate ThreadForge tenant isolation")
    parser.add_argument("--actor-spiffe-id", required=True, help="Actor SPIFFE identity")
    parser.add_argument("--request-namespace", required=True, help="Target namespace")
    parser.add_argument("--json", dest="as_json", action="store_true", help="Emit JSON output")
    args = parser.parse_args()

    try:
        actor_tenant = extract_tenant_from_spiffe(args.actor_spiffe_id)
        validate_tenant_access(args.actor_spiffe_id, args.request_namespace)
    except TenantIsolationError as exc:
        if args.as_json:
            print(json.dumps({"status": "DENY", "reason": str(exc)}, sort_keys=True))
        else:
            print(f"[FAIL] {exc}")
        return 2

    if args.as_json:
        print(
            json.dumps(
                {
                    "status": "ALLOW",
                    "actor_namespace": actor_tenant,
                    "request_namespace": args.request_namespace,
                },
                sort_keys=True,
            )
        )
    else:
        print("ALLOW")
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
