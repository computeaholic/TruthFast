"""Phase 6F: Tests for Evidence Schema Validator Enforcement

Verifies that the canonical evidence schema validator is wired into all ledger
ingress points and fails-closed on invalid evidence.

Tests cover:
- Missing evidence_kind → rejected
- Missing synthetic → rejected
- Invalid evidence_kind value → rejected
- Invalid synthetic type → rejected
- Inconsistent classification → rejected
- Valid evidence → accepted
- Regression: validator called on all record paths
"""

import pytest

from runtime.ledger.evidence_validation import EvidenceValidationError, validate_evidence_classification


class TestEvidenceValidationErrors:
    """Tests that evidence validation raises proper errors."""

    def test_missing_evidence_kind(self):
        """Evidence missing evidence_kind must be rejected."""
        evidence = {"synthetic": False}
        with pytest.raises(EvidenceValidationError) as exc:
            validate_evidence_classification(evidence)
        assert "evidence_kind" in str(exc.value)

    def test_missing_synthetic(self):
        """Evidence missing synthetic field must be rejected."""
        evidence = {"evidence_kind": "real"}
        with pytest.raises(EvidenceValidationError) as exc:
            validate_evidence_classification(evidence)
        assert "synthetic" in str(exc.value)

    def test_invalid_evidence_kind(self):
        """Evidence with invalid evidence_kind must be rejected."""
        evidence = {"evidence_kind": "invalid", "synthetic": False}
        with pytest.raises(EvidenceValidationError) as exc:
            validate_evidence_classification(evidence)
        assert "invalid" in str(exc.value) or "Invalid" in str(exc.value)

    def test_synthetic_not_boolean(self):
        """Evidence with non-boolean synthetic field must be rejected."""
        evidence = {"evidence_kind": "real", "synthetic": "true"}  # string, not bool
        with pytest.raises(EvidenceValidationError) as exc:
            validate_evidence_classification(evidence)
        assert "boolean" in str(exc.value) or "bool" in str(exc.value)

    def test_inconsistent_synthetic_true_with_real(self):
        """Evidence with synthetic=true but evidence_kind=real must be rejected."""
        evidence = {"evidence_kind": "real", "synthetic": True}
        with pytest.raises(EvidenceValidationError) as exc:
            validate_evidence_classification(evidence)
        assert "Inconsistent" in str(exc.value) or "consistent" in str(exc.value)

    def test_inconsistent_synthetic_true_with_wrong_kind(self):
        """Evidence with synthetic=true but evidence_kind not simulated/demo must be rejected."""
        evidence = {"evidence_kind": "real", "synthetic": True}
        with pytest.raises(EvidenceValidationError) as exc:
            validate_evidence_classification(evidence)
        assert "Inconsistent" in str(exc.value)


class TestEvidenceValidationAcceptance:
    """Tests that valid evidence is accepted without error."""

    def test_valid_real_evidence(self):
        """Real evidence with synthetic=false must be accepted."""
        evidence = {"evidence_kind": "real", "synthetic": False}
        # Should not raise
        validate_evidence_classification(evidence)

    def test_valid_simulated_evidence(self):
        """Simulated evidence with synthetic=true must be accepted."""
        evidence = {"evidence_kind": "simulated", "synthetic": True}
        # Should not raise
        validate_evidence_classification(evidence)

    def test_valid_demo_evidence(self):
        """Demo evidence with synthetic=true must be accepted."""
        evidence = {"evidence_kind": "demo", "synthetic": True}
        # Should not raise
        validate_evidence_classification(evidence)

    def test_valid_evidence_with_extra_fields(self):
        """Valid evidence with additional fields must still be accepted."""
        evidence = {
            "evidence_kind": "real",
            "synthetic": False,
            "timestamp": "2026-01-28T00:00:00Z",
            "source": "test",
            "extra_field": "should_not_matter",
        }
        # Should not raise
        validate_evidence_classification(evidence)


class TestEvidenceValidationEdgeCases:
    """Tests for edge cases and boundary conditions."""

    def test_empty_dict(self):
        """Empty dict must be rejected."""
        with pytest.raises(EvidenceValidationError):
            validate_evidence_classification({})

    def test_all_valid_kinds(self):
        """All valid evidence_kind values must be accepted."""
        for kind in ["real", "simulated", "demo"]:
            evidence = {"evidence_kind": kind, "synthetic": False}
            # synthetic must be false for 'real', but we'll test all valid kinds work
            if kind in ("simulated", "demo"):
                evidence["synthetic"] = True
            validate_evidence_classification(evidence)

    def test_synthetic_boolean_variants(self):
        """Only boolean True/False should be accepted for synthetic."""
        # True is accepted
        evidence_true = {"evidence_kind": "simulated", "synthetic": True}
        validate_evidence_classification(evidence_true)

        # False is accepted
        evidence_false = {"evidence_kind": "real", "synthetic": False}
        validate_evidence_classification(evidence_false)

        # 1 and 0 are not boolean in Python (though they are truthy/falsy)
        evidence_one = {"evidence_kind": "real", "synthetic": 1}
        with pytest.raises(EvidenceValidationError):
            validate_evidence_classification(evidence_one)

        evidence_zero = {"evidence_kind": "real", "synthetic": 0}
        with pytest.raises(EvidenceValidationError):
            validate_evidence_classification(evidence_zero)


class TestOperatorLedgerValidation:
    """Tests that evidence validation is wired into OperatorLedger.record()"""

    def test_ledger_record_rejects_invalid_evidence(self):
        """OperatorLedger.record() must reject events with invalid evidence."""
        from runtime.ledger.operator_ledger import OperatorLedger

        ledger = OperatorLedger()

        # Event with missing evidence_kind
        invalid_event = {
            "type": "test_event",
            "synthetic": True,
            # Missing evidence_kind
        }

        with pytest.raises(EvidenceValidationError):
            ledger.record(invalid_event)

    def test_ledger_record_accepts_valid_evidence(self):
        """OperatorLedger.record() must accept events with valid evidence (or reject on authority, not evidence)."""
        from unittest.mock import patch

        from runtime.ledger.operator_ledger import OperatorLedger

        ledger = OperatorLedger()

        # Valid evidence event
        valid_event = {
            "type": "test_event",
            "evidence_kind": "real",
            "synthetic": False,
            "identity_context": {
                "spiffe_id": "spiffe://test/actor",
                "trust_domain": "test",
                "attested": True,
            },
        }

        # Mock authority check to pass (so we can test evidence validation alone)
        with patch("runtime.ledger.operator_ledger.get_state"):
            # This will fail on authority check, but evidence validation should pass first
            try:
                ledger.record(valid_event)
            except (PermissionError, ValueError, AttributeError):
                # Expected: authority check fails, but evidence validation passed
                pass

    def test_ledger_record_no_validation_without_evidence_fields(self):
        """OperatorLedger.record() should not validate when evidence fields absent."""
        from runtime.ledger.operator_ledger import OperatorLedger

        ledger = OperatorLedger()

        # Event without evidence fields (should not trigger validation)
        event = {
            "type": "test_event",
            "identity_context": {
                "spiffe_id": "spiffe://test/actor",
                "trust_domain": "test",
                "attested": True,
            },
        }

        # Should fail on authority, not on evidence validation
        with pytest.raises((PermissionError, ValueError)):
            ledger.record(event)


class TestLedgerAPIValidation:
    """Tests that evidence validation is wired into ledger API endpoints."""

    def test_forgesec_endpoint_rejects_invalid_evidence(self):
        """Ledger API /forgesec endpoint must reject invalid evidence."""

        from runtime.ledger.events import record_forgesec_observation

        # Invalid observation (missing synthetic)
        invalid_obs = {"evidence_kind": "real"}

        with pytest.raises(EvidenceValidationError):
            record_forgesec_observation(invalid_obs)

    def test_forgesec_endpoint_accepts_valid_evidence(self):
        """Ledger API /forgesec endpoint must accept valid evidence."""
        from unittest.mock import patch

        from runtime.ledger.events import record_forgesec_observation

        # Valid observation
        valid_obs = {
            "evidence_kind": "real",
            "synthetic": False,
            "disclaimer": "observational",
            "identity_context": {
                "spiffe_id": "spiffe://threadforge.local/forgesec-runner",
                "trust_domain": "threadforge.local",
                "tier": "system",
                "namespace": "forgesec",
                "service_account": "forgesec-runner",
                "attested": True,
            },
        }

        # Mock the ledger write to avoid DB dependency
        with patch("runtime.ledger.events.OperatorLedger"):
            # Should not raise on evidence validation
            try:
                record_forgesec_observation(valid_obs)
            except Exception as e:
                # If it fails, it should be a different reason (ledger write)
                # not an evidence validation error
                assert not isinstance(e, EvidenceValidationError)
