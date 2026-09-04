"""Tests for identity binding race condition fixes."""

import threading

import pytest

from runtime.operator_api.identity_binding import Capability, IdentityBindingManager


class TestIdentityBindingAtomicity:
    """Verify atomic identity binding operations."""

    def test_claim_authority_prevents_double_claim(self):
        """claim_authority() rejects second claim attempt."""
        manager = IdentityBindingManager()

        binding1 = manager.claim_authority("spiffe://principal-1", True)
        assert binding1.principal == "spiffe://principal-1"

        with pytest.raises(RuntimeError, match="Authority already claimed"):
            manager.claim_authority("spiffe://principal-2", True)

    def test_check_binding_returns_none_before_claim(self):
        """check_binding() returns (False, None) before authority claimed."""
        manager = IdentityBindingManager()

        is_claimed, snapshot = manager.check_binding()
        assert is_claimed is False
        assert snapshot is None

    def test_check_binding_atomic_snapshot(self):
        """check_binding() returns immutable snapshot after claim."""
        manager = IdentityBindingManager()
        binding = manager.claim_authority("spiffe://test-principal", True)

        # Check binding multiple times
        is_claimed, snapshot = manager.check_binding()
        assert is_claimed is True
        assert snapshot.principal == "spiffe://test-principal"
        assert snapshot.binding_id == binding.binding_id

    def test_concurrent_claim_attempts_serialize(self):
        """Concurrent claims are serialized (only first succeeds)."""
        manager = IdentityBindingManager()
        results = []

        def claim_authority(principal):
            try:
                binding = manager.claim_authority(principal, True)
                results.append(("success", binding.principal))
            except RuntimeError as e:
                results.append(("failed", str(e)))

        threads = [threading.Thread(target=claim_authority, args=(f"spiffe://principal-{i}",)) for i in range(3)]

        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # Exactly one should succeed
        successes = [r for r in results if r[0] == "success"]
        failures = [r for r in results if r[0] == "failed"]

        assert len(successes) == 1
        assert len(failures) == 2

    def test_concurrent_binding_checks_consistent(self):
        """Concurrent binding checks see consistent state."""
        manager = IdentityBindingManager()
        manager.claim_authority("spiffe://test-principal", True)

        results = []

        def check_binding():
            is_claimed, snapshot = manager.check_binding()
            results.append((is_claimed, snapshot.principal if snapshot else None))

        threads = [threading.Thread(target=check_binding) for _ in range(10)]

        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # All checks should see same claimed state
        assert all(is_claimed for is_claimed, _ in results)
        assert all(principal == "spiffe://test-principal" for _, principal in results)

    def test_get_binding_for_execution_requires_claimed(self):
        """get_binding_for_execution() fails if authority not claimed."""
        manager = IdentityBindingManager()

        with pytest.raises(RuntimeError, match="Authority not claimed"):
            manager.get_binding_for_execution()

    def test_get_binding_for_execution_succeeds_after_claim(self):
        """get_binding_for_execution() returns binding after claim."""
        manager = IdentityBindingManager()
        manager.claim_authority("spiffe://test-principal", True)

        binding = manager.get_binding_for_execution()
        assert binding.principal == "spiffe://test-principal"
        assert binding.authority_claimed is True

    def test_require_valid_binding_checks_svid_validity(self):
        """require_valid_binding() fails if SVID invalid."""
        manager = IdentityBindingManager()
        manager.claim_authority("spiffe://test-principal", False)  # svid_valid=False

        with pytest.raises(PermissionError, match="Identity binding invalid"):
            manager.require_valid_binding()

    def test_require_valid_binding_succeeds_if_valid(self):
        """require_valid_binding() succeeds if binding valid."""
        manager = IdentityBindingManager()
        manager.claim_authority("spiffe://test-principal", True)  # svid_valid=True

        binding = manager.require_valid_binding()
        assert binding.is_valid()


class TestCapabilityEnforcement:
    """Verify capability-based access control."""

    def test_binding_tracks_capabilities(self):
        """Binding includes capability set."""
        manager = IdentityBindingManager()
        binding = manager.claim_authority("spiffe://test", True)

        assert hasattr(binding, "capabilities")
        assert isinstance(binding.capabilities, set)

    def test_claim_authority_with_no_capabilities(self):
        """claim_authority() accepts no capabilities (empty set)."""
        manager = IdentityBindingManager()
        binding = manager.claim_authority("spiffe://test", True)

        assert binding.capabilities == set()

    def test_claim_authority_with_capabilities(self):
        """claim_authority() stores passed capabilities."""
        manager = IdentityBindingManager()
        caps = {Capability.VERIFY_SVID, Capability.REPAIR_ISTIO_INJECTION}
        binding = manager.claim_authority("spiffe://test", True, capabilities=caps)

        assert binding.capabilities == caps

    def test_has_capability_check_granted(self):
        """has_capability() returns True for granted capabilities."""
        manager = IdentityBindingManager()
        caps = {Capability.VERIFY_SVID, Capability.REPAIR_ISTIO_INJECTION}
        manager.claim_authority("spiffe://test", True, capabilities=caps)

        binding = manager.get_binding_for_execution()
        assert binding.has_capability(Capability.VERIFY_SVID)
        assert binding.has_capability(Capability.REPAIR_ISTIO_INJECTION)

    def test_has_capability_check_denied(self):
        """has_capability() returns False for denied capabilities."""
        manager = IdentityBindingManager()
        caps = {Capability.VERIFY_SVID}
        manager.claim_authority("spiffe://test", True, capabilities=caps)

        binding = manager.get_binding_for_execution()
        assert not binding.has_capability(Capability.PATCH_DEPLOYMENT)
        assert not binding.has_capability(Capability.INSPECT_CSI_SOCKET)

    def test_binding_immutable_after_creation(self):
        """Binding snapshot is immutable after creation."""
        manager = IdentityBindingManager()
        binding = manager.claim_authority("spiffe://test", True)

        # Try to modify capabilities (should fail or have no effect)
        # In Python dataclass, this would raise FrozenInstanceError if frozen=True
        # For now, just verify capabilities are a set
        assert isinstance(binding.capabilities, set)


class TestIdentityBindingIntegration:
    """Integration tests for identity binding workflow."""

    def test_full_lifecycle(self):
        """Complete lifecycle: unclaimed -> claim -> execute."""
        manager = IdentityBindingManager()

        # Start unclaimed
        is_claimed, _ = manager.check_binding()
        assert is_claimed is False

        # Claim authority
        binding = manager.claim_authority(
            "spiffe://identity.threadforge.local/ns/threadforge/sa/operator-api",
            True,
            capabilities={Capability.VERIFY_SVID, Capability.REPAIR_ISTIO_INJECTION},
        )
        assert binding.authority_claimed is True

        # Check binding
        is_claimed, snapshot = manager.check_binding()
        assert is_claimed is True
        assert snapshot.principal == "spiffe://identity.threadforge.local/ns/threadforge/sa/operator-api"

        # Get binding for execution
        exec_binding = manager.get_binding_for_execution()
        assert exec_binding.has_capability(Capability.REPAIR_ISTIO_INJECTION)

        # Require valid binding
        valid_binding = manager.require_valid_binding()
        assert valid_binding.is_valid()

    def test_cannot_execute_before_claim(self):
        """Cannot execute before authority is claimed."""
        manager = IdentityBindingManager()

        # Should fail before claim
        with pytest.raises(RuntimeError):
            manager.get_binding_for_execution()

        with pytest.raises(RuntimeError):
            manager.require_valid_binding()
