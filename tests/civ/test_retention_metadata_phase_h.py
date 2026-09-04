"""
Phase H: Retention Metadata Standardization Tests

Validates that all audit and decision artifacts emit standardized retention metadata.

Test Categories:
1. Schema Validation - Test RetentionMetadata dataclass structure
2. Decision Artifacts - Test Civ decision retention metadata emission
3. Gate Evidence - Test doctor gate retention metadata
4. Delegation Audits - Test delegation audit retention metadata
5. Emission Enforcement - Test that metadata is always written
6. Global Invariants - Test Phase H retention constraints

Phase H Invariants:
- All canonical artifacts MUST emit retention metadata
- Metadata is descriptive, not prescriptive (no automated purging)
- Retention files use .retention.json suffix
- Missing metadata = implementation error (fail-closed validation)
"""

import json
from datetime import datetime, timezone

import pytest

from runtime.civ.provenance import ArtifactWriter, ProvenanceBuilder
from runtime.civ.provenance.artifact_signing import ArtifactSigner
from runtime.civ.retention_metadata import (
    RetentionClass,
    RetentionMetadata,
    create_decision_retention_metadata,
    create_delegation_audit_retention_metadata,
    create_gate_evidence_retention_metadata,
    read_retention_metadata,
    write_retention_metadata,
)


class TestRetentionMetadataSchema:
    """Test retention metadata schema and structure."""

    def test_retention_metadata_structure(self):
        """Test RetentionMetadata dataclass has all required fields."""
        metadata = RetentionMetadata(
            artifact_type="decision",
            artifact_id="test-123",
            created_at="2026-01-27T00:00:00Z",
            retention_class=RetentionClass.CANONICAL,
            retention_days=2555,
            authority_level="non_binding",
            source_system="civ_engine",
            description="Test artifact",
        )

        assert metadata.artifact_type == "decision"
        assert metadata.artifact_id == "test-123"
        assert metadata.created_at == "2026-01-27T00:00:00Z"
        assert metadata.retention_class == RetentionClass.CANONICAL
        assert metadata.retention_days == 2555
        assert metadata.authority_level == "non_binding"
        assert metadata.source_system == "civ_engine"
        assert metadata.description == "Test artifact"

    def test_retention_metadata_immutable(self):
        """Test that RetentionMetadata is immutable (frozen dataclass)."""
        metadata = RetentionMetadata(
            artifact_type="decision",
            artifact_id="test-123",
            created_at="2026-01-27T00:00:00Z",
            retention_class=RetentionClass.CANONICAL,
            retention_days=2555,
            authority_level="non_binding",
            source_system="civ_engine",
            description="Test artifact",
        )

        with pytest.raises((AttributeError, Exception)):
            metadata.retention_days = 999

    def test_retention_metadata_serialization(self):
        """Test RetentionMetadata JSON serialization."""
        metadata = RetentionMetadata(
            artifact_type="decision",
            artifact_id="test-123",
            created_at="2026-01-27T00:00:00Z",
            retention_class=RetentionClass.CANONICAL,
            retention_days=2555,
            authority_level="non_binding",
            source_system="civ_engine",
            description="Test artifact",
        )

        json_str = metadata.to_json()
        data = json.loads(json_str)

        assert data["artifact_type"] == "decision"
        assert data["artifact_id"] == "test-123"
        assert data["retention_class"] == "canonical"
        assert data["retention_days"] == 2555

    def test_retention_metadata_deserialization(self):
        """Test RetentionMetadata JSON deserialization."""
        data = {
            "artifact_type": "decision",
            "artifact_id": "test-123",
            "created_at": "2026-01-27T00:00:00Z",
            "retention_class": "canonical",
            "retention_days": 2555,
            "authority_level": "non_binding",
            "source_system": "civ_engine",
            "description": "Test artifact",
        }

        metadata = RetentionMetadata.from_dict(data)

        assert metadata.artifact_type == "decision"
        assert metadata.retention_class == RetentionClass.CANONICAL


class TestDecisionArtifactRetention:
    """Test retention metadata for Civ decision artifacts."""

    def test_create_decision_retention_metadata(self):
        """Test creating retention metadata for a decision artifact."""
        decision_id = "test-decision-hash-123"
        created_at = "2026-01-27T00:00:00Z"

        metadata = create_decision_retention_metadata(decision_id, created_at)

        assert metadata.artifact_type == "decision"
        assert metadata.artifact_id == decision_id
        assert metadata.created_at == created_at
        assert metadata.retention_class == RetentionClass.CANONICAL
        assert metadata.retention_days == 2555  # 7 years
        assert metadata.authority_level == "non_binding"
        assert metadata.source_system == "civ_engine"

    def test_decision_retention_defaults_to_now(self):
        """Test that decision retention metadata defaults to current time."""
        before = datetime.now(timezone.utc).isoformat()
        metadata = create_decision_retention_metadata("test-123")
        after = datetime.now(timezone.utc).isoformat()

        # Timestamp should be between before and after
        assert before <= metadata.created_at <= after

    def test_artifact_writer_emits_retention_metadata(self, tmp_path):
        """Test that ArtifactWriter emits retention metadata for decisions."""
        # Create test signing key
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

        test_key = Ed25519PrivateKey.generate()
        signer = ArtifactSigner(private_key=test_key)

        # Create writer with temp directory
        writer = ArtifactWriter(artifact_root=tmp_path, signer=signer)

        # Create minimal decision
        builder = ProvenanceBuilder(query_execution_context={})
        decision = builder.build_budget_pressure_decision(
            utilization_percent=85.0,
            denial_pressure=0.85,
            minutes_to_breach=30,
            dominant_contributors=[],
        )

        # Write decision
        result = writer.write_decision(decision)

        # Verify retention metadata file exists
        decision_id = decision.decision_id
        json_path = tmp_path / f"{decision_id}.json"
        retention_path = tmp_path / f"{decision_id}.json.retention.json"

        assert json_path.exists(), "Decision JSON should exist"
        assert retention_path.exists(), "Retention metadata should exist alongside decision JSON"

        # Read and validate retention metadata
        retention_metadata = read_retention_metadata(retention_path)
        assert retention_metadata.artifact_type == "decision"
        assert retention_metadata.artifact_id == str(decision_id)
        assert retention_metadata.retention_class == RetentionClass.CANONICAL
        assert retention_metadata.retention_days == 2555


class TestGateEvidenceRetention:
    """Test retention metadata for doctor gate evidence."""

    def test_create_gate_evidence_retention_metadata(self):
        """Test creating retention metadata for gate evidence."""
        gate_id = "collector"
        drill_id = "drill-20260127-001"
        created_at = "2026-01-27T00:00:00Z"

        metadata = create_gate_evidence_retention_metadata(gate_id, drill_id, created_at)

        assert metadata.artifact_type == "gate_evidence"
        assert metadata.artifact_id == f"{gate_id}-{drill_id}"
        assert metadata.created_at == created_at
        assert metadata.retention_class == RetentionClass.EPHEMERAL
        assert metadata.retention_days == 90
        assert metadata.authority_level == "evidence_only"
        assert metadata.source_system == "doctor_gate"

    def test_gate_evidence_is_ephemeral(self):
        """Test that gate evidence uses EPHEMERAL retention class."""
        metadata = create_gate_evidence_retention_metadata("spire", "drill-123")

        assert metadata.retention_class == RetentionClass.EPHEMERAL
        assert metadata.retention_days == 90  # Short retention for probes


class TestDelegationAuditRetention:
    """Test retention metadata for delegation audit artifacts."""

    def test_create_delegation_audit_retention_metadata(self):
        """Test creating retention metadata for delegation audit."""
        audit_id = "delegation-audit-20260127"
        created_at = "2026-01-27T00:00:00Z"

        metadata = create_delegation_audit_retention_metadata(audit_id, created_at)

        assert metadata.artifact_type == "delegation_audit"
        assert metadata.artifact_id == audit_id
        assert metadata.created_at == created_at
        assert metadata.retention_class == RetentionClass.CANONICAL
        assert metadata.retention_days == 2555
        assert metadata.authority_level == "procedural"
        assert metadata.source_system == "delegation_audit"

    def test_delegation_audit_is_canonical(self):
        """Test that delegation audits use CANONICAL retention class."""
        metadata = create_delegation_audit_retention_metadata("audit-123")

        assert metadata.retention_class == RetentionClass.CANONICAL
        assert metadata.retention_days == 2555  # Long retention for audits


class TestRetentionMetadataEmission:
    """Test retention metadata file emission."""

    def test_write_retention_metadata(self, tmp_path):
        """Test writing retention metadata to disk."""
        artifact_path = tmp_path / "test-artifact.json"
        artifact_path.write_text('{"test": "data"}')

        metadata = RetentionMetadata(
            artifact_type="decision",
            artifact_id="test-123",
            created_at="2026-01-27T00:00:00Z",
            retention_class=RetentionClass.CANONICAL,
            retention_days=2555,
            authority_level="non_binding",
            source_system="civ_engine",
            description="Test artifact",
        )

        retention_path = write_retention_metadata(metadata, artifact_path)

        assert retention_path.exists()
        assert retention_path.name == "test-artifact.json.retention.json"

        # Read back and verify
        read_metadata = read_retention_metadata(retention_path)
        assert read_metadata.artifact_id == "test-123"
        assert read_metadata.retention_class == RetentionClass.CANONICAL

    def test_retention_metadata_alongside_artifact(self, tmp_path):
        """Test that retention metadata is written alongside artifact."""
        artifact_path = tmp_path / "decision.json"
        artifact_path.write_text('{"decision": "data"}')

        metadata = create_decision_retention_metadata("test-decision")
        retention_path = write_retention_metadata(metadata, artifact_path)

        # Retention file should be in same directory
        assert retention_path.parent == artifact_path.parent
        assert retention_path.name == "decision.json.retention.json"


class TestRetentionMetadataGlobalInvariants:
    """Test global Phase H invariants for retention metadata."""

    def test_no_automated_purging_logic(self):
        """Test that retention metadata is descriptive only (no purging logic)."""
        # This test verifies the module contains no purging/deletion code
        import inspect

        import runtime.civ.retention_metadata as retention_module

        source = inspect.getsource(retention_module)

        # Should not contain purging/deletion keywords
        forbidden = [
            "DELETE FROM",
            "DROP TABLE",
            "TRUNCATE",
            "rm -rf",
            "unlink",
            "shutil.rmtree",
        ]

        for keyword in forbidden:
            assert (
                keyword.lower() not in source.lower()
            ), f"Retention module should not contain '{keyword}' (descriptive only)"

    def test_canonical_artifacts_use_7_year_retention(self):
        """Test that canonical artifacts use 7-year retention guideline."""
        decision_metadata = create_decision_retention_metadata("test-123")
        delegation_metadata = create_delegation_audit_retention_metadata("audit-123")

        assert decision_metadata.retention_days == 2555  # ~7 years
        assert delegation_metadata.retention_days == 2555

    def test_ephemeral_artifacts_use_90_day_retention(self):
        """Test that ephemeral artifacts use 90-day retention guideline."""
        gate_metadata = create_gate_evidence_retention_metadata("collector", "drill-123")

        assert gate_metadata.retention_days == 90
        assert gate_metadata.retention_class == RetentionClass.EPHEMERAL

    def test_retention_metadata_is_machine_readable(self, tmp_path):
        """Test that retention metadata is valid JSON."""
        artifact_path = tmp_path / "test.json"
        artifact_path.write_text("{}")

        metadata = create_decision_retention_metadata("test-123")
        retention_path = write_retention_metadata(metadata, artifact_path)

        # Should be parseable JSON
        data = json.loads(retention_path.read_text())
        assert "artifact_type" in data
        assert "retention_days" in data
        assert "retention_class" in data
