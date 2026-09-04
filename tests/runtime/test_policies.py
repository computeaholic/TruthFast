import pytest

from runtime.identity.capability_resolver import CapabilityResolver
from runtime.identity.context import IdentityContext


def test_tier0_kernel_root_grants():
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/ns/sa/sa/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="ns",
        service_account="sa",
        attested=True,
    )

    caps = resolver.derive_capabilities(identity)
    assert "kernel.execute" in caps.capabilities
    assert "authority.delegate" in caps.capabilities


def test_operator_ai_service_account():
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/ops/sa/operator-ai/tierX",
        trust_domain="identity.threadforge.local",
        tier="tierX",
        namespace="ops",
        service_account="operator-ai",
        attested=True,
    )

    caps = resolver.derive_capabilities(identity)
    assert "kernel.execute" in caps.capabilities
    assert "authority.delegate" in caps.capabilities


def test_threadforge_namespace_system_tier():
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/threadforge/sa/svc/system",
        trust_domain="identity.threadforge.local",
        tier="system",
        namespace="threadforge",
        service_account="svc",
        attested=True,
    )

    caps = resolver.derive_capabilities(identity)
    assert "kernel.execute" in caps.capabilities


def test_no_matching_policy_raises():
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/x/sa/y/unknown",
        trust_domain="identity.threadforge.local",
        tier="unknown",
        namespace="x",
        service_account="y",
        attested=True,
    )

    with pytest.raises(RuntimeError):
        resolver.derive_capabilities(identity)


# Phase 10: Capability Completion Tests


def test_tier0_has_storage_list():
    """tier0 kernel_root should have storage.list capability."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/root/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="sys",
        service_account="root",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "storage.list" in caps.capabilities


def test_tier0_has_vector_embed():
    """tier0 kernel_root should have vector.embed capability."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/root/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="sys",
        service_account="root",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "vector.embed" in caps.capabilities


def test_tier0_has_vector_route_restricted():
    """tier0 kernel_root should have vector.route (restricted capability)."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/root/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="sys",
        service_account="root",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "vector.route" in caps.capabilities


def test_tier1_has_storage_list():
    """tier1 system_services should have storage.list capability."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/svc/tier1",
        trust_domain="identity.threadforge.local",
        tier="tier1",
        namespace="sys",
        service_account="svc",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "storage.list" in caps.capabilities


def test_tier1_has_vector_embed():
    """tier1 system_services should have vector.embed capability."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/svc/tier1",
        trust_domain="identity.threadforge.local",
        tier="tier1",
        namespace="sys",
        service_account="svc",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "vector.embed" in caps.capabilities


def test_tier1_lacks_vector_route():
    """tier1 system_services should NOT have vector.route (restricted)."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/svc/tier1",
        trust_domain="identity.threadforge.local",
        tier="tier1",
        namespace="sys",
        service_account="svc",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "vector.route" not in caps.capabilities


def test_tier2_has_storage_list():
    """tier2 user_workloads should have storage.list capability."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="worker",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "storage.list" in caps.capabilities


def test_tier2_lacks_vector_embed():
    """tier2 user_workloads should NOT have vector.embed capability."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="worker",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "vector.embed" not in caps.capabilities


def test_tier2_lacks_vector_route():
    """tier2 user_workloads should NOT have vector.route (restricted)."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="worker",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "vector.route" not in caps.capabilities


def test_tier3_lacks_storage_list():
    """tier3 restricted_access should NOT have storage.list capability."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="guest",
        service_account="viewer",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "storage.list" not in caps.capabilities


def test_tier3_lacks_vector_embed():
    """tier3 restricted_access should NOT have vector.embed capability."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="guest",
        service_account="viewer",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "vector.embed" not in caps.capabilities


def test_operator_ai_has_all_new_capabilities():
    """operator-ai service account should have storage.list, vector.embed, vector.route."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/ops/sa/operator-ai/tierX",
        trust_domain="identity.threadforge.local",
        tier="tierX",
        namespace="ops",
        service_account="operator-ai",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "storage.list" in caps.capabilities
    assert "vector.embed" in caps.capabilities
    assert "vector.route" in caps.capabilities


def test_threadforge_system_has_all_new_capabilities():
    """threadforge namespace system tier should have storage.list, vector.embed, vector.route."""
    resolver = CapabilityResolver()
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/threadforge/sa/core/system",
        trust_domain="identity.threadforge.local",
        tier="system",
        namespace="threadforge",
        service_account="core",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)
    assert "storage.list" in caps.capabilities
    assert "vector.embed" in caps.capabilities
    assert "vector.route" in caps.capabilities
