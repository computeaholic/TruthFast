#!/usr/bin/env python3
"""ThreadForge delegation CLI tool.

Provides visibility and control over active delegations.
"""

import argparse
import json
import sys
from datetime import datetime, timezone

from api.core.identity_config import TRUST_DOMAIN
from runtime.identity.capability_resolver import derive_capabilities
from runtime.identity.context import IdentityContext
from runtime.identity.delegation import DelegatedCapability
from runtime.identity.delegation_store import get_delegation_store
from runtime.identity.identity_graph import get_identity_graph


def format_delegation(delegation: DelegatedCapability) -> dict:
    """Format delegation for display."""
    return {
        "delegation_id": delegation.delegation_id,
        "source": delegation.source_spiffe_id,
        "delegate": delegation.delegate_spiffe_id,
        "capabilities": list(delegation.capabilities),
        "issued_at": delegation.issued_at.isoformat(),
        "expires_at": delegation.expires_at.isoformat(),
        "justification": delegation.justification,
        "is_active": delegation.is_active,
        "is_expired": delegation.is_expired,
        "is_revoked": delegation.is_revoked,
        "revoked_at": delegation.revoked_at.isoformat() if delegation.revoked_at else None,
    }


def cmd_list(args):
    """List delegations."""
    store = get_delegation_store()

    if args.source:
        # List all delegations from source
        delegations = store.get_all_delegations_from_source(args.source)
        print(f"Delegations issued by {args.source}:")
    else:
        # List active delegations for delegate
        delegations = store.get_active_delegations_for_delegate(args.spiffe_id)
        print(f"Active delegations for {args.spiffe_id}:")

    if not delegations:
        print("  (none)")
        return

    for delegation in delegations:
        print(f"\n  Delegation ID: {delegation.delegation_id}")
        print(f"    Source: {delegation.source_spiffe_id}")
        print(f"    Delegate: {delegation.delegate_spiffe_id}")
        print(f"    Capabilities: {', '.join(delegation.capabilities)}")
        print(f"    Issued: {delegation.issued_at.isoformat()}")
        print(f"    Expires: {delegation.expires_at.isoformat()}")
        print(f"    Active: {delegation.is_active}")
        if delegation.is_revoked:
            print(f"    Revoked: {delegation.revoked_at.isoformat()}")
        print(f"    Justification: {delegation.justification}")


def cmd_show(args):
    """Show delegation details."""
    store = get_delegation_store()
    delegation = store.get_delegation(args.delegation_id)

    if not delegation:
        print(f"Delegation not found: {args.delegation_id}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(format_delegation(delegation), indent=2))
    else:
        print(f"Delegation ID: {delegation.delegation_id}")
        print(f"Source: {delegation.source_spiffe_id}")
        print(f"Delegate: {delegation.delegate_spiffe_id}")
        print(f"Capabilities: {', '.join(delegation.capabilities)}")
        print(f"Policy Source: {delegation.policy_source}")
        print(f"Issued: {delegation.issued_at.isoformat()}")
        print(f"Expires: {delegation.expires_at.isoformat()}")
        print(f"Justification: {delegation.justification}")
        print("")
        print("Status:")
        print(f"  Active: {delegation.is_active}")
        print(f"  Expired: {delegation.is_expired}")
        print(f"  Revoked: {delegation.is_revoked}")
        if delegation.is_revoked:
            print(f"  Revoked At: {delegation.revoked_at.isoformat()}")


def cmd_capabilities(args):
    """Show effective capabilities for an identity."""
    # Parse SPIFFE ID to construct IdentityContext
    # This is simplified — real implementation would parse SPIFFE ID properly
    identity = IdentityContext(
        spiffe_id=args.spiffe_id,
        trust_domain=TRUST_DOMAIN,
        tier=args.tier,
        namespace=args.namespace,
        service_account=args.service_account,
        attested=True,
    )

    caps = derive_capabilities(identity)

    print(f"Effective capabilities for {args.spiffe_id}:")
    print(f"  Policy: {caps.derived_from_policy}")
    print(f"  Capabilities ({len(caps.capabilities)}):")
    for cap in sorted(caps.capabilities):
        print(f"    - {cap}")


def cmd_blast_radius(args):
    """Show blast radius for a source identity."""
    graph = get_identity_graph()
    affected = graph.get_delegation_blast_radius(args.source)

    print(f"Blast radius for {args.source}:")
    if not affected:
        print("  (no active delegations)")
        return

    print(f"  {len(affected)} identities would lose delegated authority:")
    for identity in sorted(affected):
        print(f"    - {identity}")


def cmd_sources(args):
    """Show delegation sources for an identity."""
    graph = get_identity_graph()
    sources = graph.get_delegation_sources(args.spiffe_id)

    print(f"Delegation sources for {args.spiffe_id}:")
    if not sources:
        print("  (no active delegations)")
        return

    print(f"  {len(sources)} identities have delegated authority:")
    for source in sorted(sources):
        print(f"    - {source}")


def cmd_audit(args):
    """Export delegation audit report."""
    store = get_delegation_store()
    graph = get_identity_graph()

    all_delegations = []
    for delegation in store._delegations.values():
        all_delegations.append(format_delegation(delegation))

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "total_delegations": len(all_delegations),
        "active_delegations": len([d for d in all_delegations if d["is_active"]]),
        "expired_delegations": len([d for d in all_delegations if d["is_expired"]]),
        "revoked_delegations": len([d for d in all_delegations if d["is_revoked"]]),
        "delegations": all_delegations,
    }

    if args.output:
        with open(args.output, "w") as f:
            json.dump(report, f, indent=2)
        print(f"Audit report written to {args.output}")
    else:
        print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(description="ThreadForge delegation management")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # List command
    parser_list = subparsers.add_parser("list", help="List delegations")
    parser_list.add_argument("spiffe_id", nargs="?", help="Delegate SPIFFE ID")
    parser_list.add_argument("--source", help="List delegations from this source")
    parser_list.set_defaults(func=cmd_list)

    # Show command
    parser_show = subparsers.add_parser("show", help="Show delegation details")
    parser_show.add_argument("delegation_id", help="Delegation ID")
    parser_show.add_argument("--json", action="store_true", help="Output as JSON")
    parser_show.set_defaults(func=cmd_show)

    # Capabilities command
    parser_caps = subparsers.add_parser("capabilities", help="Show effective capabilities")
    parser_caps.add_argument("spiffe_id", help="Identity SPIFFE ID")
    parser_caps.add_argument("--tier", default="tier2", help="Identity tier")
    parser_caps.add_argument("--namespace", default="app", help="Identity namespace")
    parser_caps.add_argument("--service-account", default="svc", help="Service account")
    parser_caps.set_defaults(func=cmd_capabilities)

    # Blast radius command
    parser_blast = subparsers.add_parser("blast-radius", help="Show delegation blast radius")
    parser_blast.add_argument("source", help="Source SPIFFE ID")
    parser_blast.set_defaults(func=cmd_blast_radius)

    # Sources command
    parser_sources = subparsers.add_parser("sources", help="Show delegation sources")
    parser_sources.add_argument("spiffe_id", help="Delegate SPIFFE ID")
    parser_sources.set_defaults(func=cmd_sources)

    # Audit command
    parser_audit = subparsers.add_parser("audit", help="Generate delegation audit report")
    parser_audit.add_argument("--output", "-o", help="Output file (default: stdout)")
    parser_audit.set_defaults(func=cmd_audit)

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    args.func(args)


if __name__ == "__main__":
    main()
