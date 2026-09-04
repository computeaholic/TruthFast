#!/usr/bin/env python3
"""Identity-first RBAC mapping for ThreadForge.

This module intentionally fail-closes: unmapped identities raise RBACResolutionError.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass


class RBACResolutionError(ValueError):
    """Raised when a SPIFFE ID cannot be mapped to a known role."""


# Minimal, explicit enterprise mapping. Keep deterministic and reviewable.
_ROLE_BY_SPIFFE: dict[str, str] = {
    "spiffe://threadforge/ns/threadforge-test/sa/test-client": "test-client",
    "spiffe://identity.threadforge.local/ns/threadforge-test/sa/test-client": "test-client",
    "spiffe://threadforge/ns/threadforge-test/sa/default": "test-default",
    "spiffe://identity.threadforge.local/ns/threadforge-test/sa/default": "test-default",
    "spiffe://threadforge/ns/observability/sa/grafana": "observability-reader",
    "spiffe://identity.threadforge.local/ns/observability/sa/grafana": "observability-reader",
    "spiffe://threadforge/ns/observability/sa/prometheus": "observability-reader",
    "spiffe://identity.threadforge.local/ns/observability/sa/prometheus": "observability-reader",
    "spiffe://threadforge/ns/threadforge-system/sa/threadforge-notifier": "notifier",
    "spiffe://identity.threadforge.local/ns/threadforge-system/sa/threadforge-notifier": "notifier",
    "spiffe://threadforge/ns/istio-system/sa/istio-ingressgateway": "ingress-gateway",
    "spiffe://identity.threadforge.local/ns/istio-system/sa/istio-ingressgateway": "ingress-gateway",
    "spiffe://identity.threadforge.local/ns/istio-system/sa/istio-ingressgateway-service-account": "ingress-gateway",
    "spiffe://threadforge/ns/spire-system/sa/spire-server": "identity-control-plane",
    "spiffe://identity.threadforge.local/ns/spire-system/sa/spire-server": "identity-control-plane",
}


@dataclass(frozen=True)
class RBACResolution:
    spiffe_id: str
    role: str


def resolve_role(spiffe_id: str) -> str:
    """Resolve a SPIFFE identity to a logical role.

    Args:
        spiffe_id: Full SPIFFE URI, for example
            "spiffe://threadforge/ns/threadforge-test/sa/test-client".

    Returns:
        The logical role string.

    Raises:
        RBACResolutionError: if spiffe_id is unknown or malformed.
    """
    normalized = (spiffe_id or "").strip()
    if not normalized.startswith("spiffe://"):
        raise RBACResolutionError(f"invalid SPIFFE identity format: {spiffe_id!r}")

    role = _ROLE_BY_SPIFFE.get(normalized)
    if role is None:
        raise RBACResolutionError(f"unmapped SPIFFE identity: {normalized}")
    return role


def resolve(spiffe_id: str) -> RBACResolution:
    return RBACResolution(spiffe_id=spiffe_id, role=resolve_role(spiffe_id))


def _cli() -> int:
    parser = argparse.ArgumentParser(description="Resolve SPIFFE identity to ThreadForge role")
    parser.add_argument("--resolve", dest="spiffe_id", required=True, help="SPIFFE identity to resolve")
    parser.add_argument("--json", dest="as_json", action="store_true", help="Emit JSON")
    args = parser.parse_args()

    try:
        result = resolve(args.spiffe_id)
    except RBACResolutionError as exc:
        print(f"[FAIL] {exc}")
        return 2

    if args.as_json:
        print(json.dumps({"spiffe_id": result.spiffe_id, "role": result.role}, sort_keys=True))
    else:
        print(result.role)
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
