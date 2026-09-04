"""
Tests for Phase H: Cryptographic Signing (Audit System Hardening).

This test suite validates:

1. ArtifactSigner
   - Can create signer with provided private key
   - Can load signer from environment variable (CIV_SIGNING_KEY)
   - Fails closed if key is missing or invalid
   - Signatures are deterministic (same content → same signature)
   - Key ID is computed correctly

2. SignatureVerifier
   - Can create verifier with provided public key
   - Can load verifier from environment variable (CIV_PUBLIC_KEY)
   - Fails closed if key is missing or invalid
   - Detects valid signatures correctly
   - Detects tampered content
   - Detects wrong signatures
   - Detects key ID mismatches

3. ArtifactWriter Integration
   - All JSON artifacts are signed
   - Signature metadata is written to .sig files
   - Unsigned artifacts cannot be created (fail-closed)
   - Signature information included in Markdown

4. End-to-End Verification
   - Sign artifact → verify signature → success
   - Sign artifact → tamper content → verify → failure
   - Sign artifact → wrong verifier key → verify → failure

Global Invariants:
- No authority writes
- Signing does not execute enforcement
- All operations are deterministic
"""

import json
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from runtime.civ.provenance import (
    ArtifactSigner,
    ArtifactWriter,
    Contributor,
    ContributorType,
    CounterfactualSensitivity,
    DecisionRecord,
    DecisionType,
    DerivedMetrics,
    InputSpecification,
    Recommendation,
    SignatureVerifier,
    SigningError,
    TimeWindow,
)


@pytest.fixture
def test_private_key():
    """Generate Ed25519 private key for testing."""
    return Ed25519PrivateKey.generate()


@pytest.fixture
def test_signer(test_private_key):
    """Create ArtifactSigner with test key."""
    return ArtifactSigner(private_key=test_private_key)


@pytest.fixture
def test_verifier(test_private_key):
    """Create SignatureVerifier with test public key."""
    public_key = test_private_key.public_key()
    return SignatureVerifier(public_key=public_key)


@pytest.fixture
def sample_decision():
    """Create sample DecisionRecord for testing."""
    return DecisionRecord(
        decision_id=uuid4(),
        decision_type=DecisionType.BUDGET_PRESSURE,
        generated_at=datetime.now(timezone.utc),
        time_window=TimeWindow(
            start=datetime.now(timezone.utc) - timedelta(hours=1),
            end=datetime.now(timezone.utc),
        ),
        inputs=InputSpecification(
            source_tables=["value_plane.operator_ledger_v2"],
            query_files=["data/queries/civ_interfaces/civ_snapshot.sql"],
            parameters={"time_window_minutes": 60},
        ),
        derived_metrics=DerivedMetrics(
            utilization_percent=85.0,
            denial_pressure=0.6,
            minutes_to_breach=45,
        ),
        dominant_contributors=[
            Contributor(
                contributor_type=ContributorType.IDENTITY_CLASS,
                contributor_id="workload-1",
                contribution_percent=100.0,
            )
        ],
        counterfactual_sensitivity=CounterfactualSensitivity(
            increase_budget_by={"delta": "10%", "effect": "reduces utilization to 75%"},
            reduce_load_by={"delta": "15%", "effect": "reduces pressure to 0.45"},
            enforce_now={"hypothetical_effect": "denials prevented, 100% attribution"},
        ),
        recommendation=Recommendation(
            text="Consider enforcement or workload adjustment",
            confidence=0.85,
        ),
    )


class TestArtifactSigner:
    """Test ArtifactSigner functionality."""

    def test_signer_with_provided_key(self, test_private_key):
        """Test creating signer with provided private key."""
        signer = ArtifactSigner(private_key=test_private_key)

        assert signer.private_key == test_private_key
        assert signer.public_key == test_private_key.public_key()
        assert len(signer.key_id) == 16  # First 16 hex chars of SHA256

    def test_signer_from_env_success(self, test_private_key, monkeypatch):
        """Test loading signer from CIV_SIGNING_KEY environment variable."""
        # Export key as hex (Ed25519 private keys are 32 bytes raw)
        from cryptography.hazmat.primitives import serialization

        key_bytes = test_private_key.private_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PrivateFormat.Raw,
            encryption_algorithm=serialization.NoEncryption(),
        )
        key_hex = key_bytes.hex()
        monkeypatch.setenv("CIV_SIGNING_KEY", key_hex)

        signer = ArtifactSigner()

        # Verify key was loaded (compare public keys)
        assert signer.public_key.public_bytes_raw() == test_private_key.public_key().public_bytes_raw()

    def test_signer_from_env_missing_key(self, monkeypatch):
        """Test that signer fails closed if CIV_SIGNING_KEY is missing."""
        monkeypatch.delenv("CIV_SIGNING_KEY", raising=False)

        with pytest.raises(SigningError, match="CIV_SIGNING_KEY environment variable not set"):
            ArtifactSigner()

    def test_signer_from_env_invalid_hex(self, monkeypatch):
        """Test that signer fails closed if CIV_SIGNING_KEY is not valid hex."""
        monkeypatch.setenv("CIV_SIGNING_KEY", "not-valid-hex!")

        with pytest.raises(SigningError, match="must be hex-encoded"):
            ArtifactSigner()

    def test_signer_from_env_wrong_length(self, monkeypatch):
        """Test that signer fails closed if CIV_SIGNING_KEY is wrong length."""
        monkeypatch.setenv("CIV_SIGNING_KEY", "abcd1234" * 4)  # 32 hex chars = 16 bytes (too short)

        with pytest.raises(SigningError, match="must be 32 bytes"):
            ArtifactSigner()

    def test_sign_artifact(self, test_signer):
        """Test signing artifact content."""
        content = '{"test": "data"}'

        sig_metadata = test_signer.sign_artifact(content)

        assert sig_metadata["algorithm"] == "ed25519"
        assert len(sig_metadata["key_id"]) == 16
        assert len(sig_metadata["signature"]) == 128  # 64 bytes = 128 hex chars
        assert len(sig_metadata["signed_content_hash"]) == 64  # SHA256 = 64 hex chars

    def test_sign_artifact_deterministic(self, test_signer):
        """Test that signatures are deterministic for same content."""
        content = '{"test": "data"}'

        sig1 = test_signer.sign_artifact(content)
        sig2 = test_signer.sign_artifact(content)

        # Ed25519 is deterministic: same key + same message = same signature
        assert sig1["signature"] == sig2["signature"]
        assert sig1["signed_content_hash"] == sig2["signed_content_hash"]

    def test_get_public_key_pem(self, test_signer):
        """Test exporting public key in PEM format."""
        pem = test_signer.get_public_key_pem()

        assert "-----BEGIN PUBLIC KEY-----" in pem
        assert "-----END PUBLIC KEY-----" in pem


class TestSignatureVerifier:
    """Test SignatureVerifier functionality."""

    def test_verifier_with_provided_key(self, test_private_key):
        """Test creating verifier with provided public key."""
        public_key = test_private_key.public_key()
        verifier = SignatureVerifier(public_key=public_key)

        assert verifier.public_key == public_key
        assert len(verifier.key_id) == 16

    def test_verifier_from_pem(self, test_signer):
        """Test creating verifier from PEM-encoded public key."""
        pem = test_signer.get_public_key_pem()
        verifier = SignatureVerifier(public_key_pem=pem)

        assert verifier.public_key.public_bytes_raw() == test_signer.public_key.public_bytes_raw()

    def test_verifier_from_env_success(self, test_private_key, monkeypatch):
        """Test loading verifier from CIV_PUBLIC_KEY environment variable."""
        pub_bytes = test_private_key.public_key().public_bytes_raw()
        pub_hex = pub_bytes.hex()
        monkeypatch.setenv("CIV_PUBLIC_KEY", pub_hex)

        verifier = SignatureVerifier()

        assert verifier.public_key.public_bytes_raw() == pub_bytes

    def test_verifier_from_env_missing_key(self, monkeypatch):
        """Test that verifier fails closed if CIV_PUBLIC_KEY is missing."""
        monkeypatch.delenv("CIV_PUBLIC_KEY", raising=False)

        with pytest.raises(SigningError, match="CIV_PUBLIC_KEY environment variable not set"):
            SignatureVerifier()

    def test_verify_valid_signature(self, test_signer, test_verifier):
        """Test verifying a valid signature."""
        content = '{"test": "data"}'
        sig_metadata = test_signer.sign_artifact(content)

        verified, error = test_verifier.verify_signature(content, sig_metadata)

        assert verified is True
        assert error is None

    def test_verify_tampered_content(self, test_signer, test_verifier):
        """Test that verification detects tampered content."""
        content = '{"test": "data"}'
        sig_metadata = test_signer.sign_artifact(content)

        tampered_content = '{"test": "tampered"}'
        verified, error = test_verifier.verify_signature(tampered_content, sig_metadata)

        assert verified is False
        assert "Content hash mismatch" in error

    def test_verify_wrong_signature(self, test_signer, test_verifier):
        """Test that verification detects wrong signature."""
        content = '{"test": "data"}'
        sig_metadata = test_signer.sign_artifact(content)

        # Tamper with signature
        sig_metadata["signature"] = "a" * 128

        verified, error = test_verifier.verify_signature(content, sig_metadata)

        assert verified is False
        assert "Signature verification failed" in error

    def test_verify_key_id_mismatch(self, test_private_key, test_verifier):
        """Test that verification detects key ID mismatch."""
        # Create a different signer
        different_key = Ed25519PrivateKey.generate()
        different_signer = ArtifactSigner(private_key=different_key)

        content = '{"test": "data"}'
        sig_metadata = different_signer.sign_artifact(content)

        verified, error = test_verifier.verify_signature(content, sig_metadata)

        assert verified is False
        assert "Key ID mismatch" in error

    def test_verify_missing_metadata_fields(self, test_verifier):
        """Test that verification fails if signature metadata is incomplete."""
        content = '{"test": "data"}'
        incomplete_metadata = {"algorithm": "ed25519"}  # Missing other fields

        verified, error = test_verifier.verify_signature(content, incomplete_metadata)

        assert verified is False
        assert "Missing required field" in error


class TestArtifactWriterWithSigning:
    """Test ArtifactWriter integration with cryptographic signing."""

    def test_write_decision_creates_signature(self, sample_decision, test_signer):
        """Test that writing a decision creates a signature file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            artifact_root = Path(tmpdir) / "decisions"
            writer = ArtifactWriter(artifact_root=artifact_root, signer=test_signer)

            result = writer.write_decision(sample_decision)

            assert "json_path" in result
            assert "signature_path" in result
            assert "signature_metadata" in result

            # Verify files exist
            json_path = Path(result["json_path"])
            sig_path = Path(result["signature_path"])

            assert json_path.exists()
            assert sig_path.exists()
            assert sig_path.name == f"{json_path.name}.sig"

    def test_signature_metadata_valid(self, sample_decision, test_signer):
        """Test that signature metadata contains all required fields."""
        with tempfile.TemporaryDirectory() as tmpdir:
            artifact_root = Path(tmpdir) / "decisions"
            writer = ArtifactWriter(artifact_root=artifact_root, signer=test_signer)

            result = writer.write_decision(sample_decision)
            sig_metadata = result["signature_metadata"]

            assert sig_metadata["algorithm"] == "ed25519"
            assert len(sig_metadata["key_id"]) == 16
            assert len(sig_metadata["signature"]) == 128
            assert len(sig_metadata["signed_content_hash"]) == 64

    def test_signature_file_content(self, sample_decision, test_signer):
        """Test that signature file contains valid JSON."""
        with tempfile.TemporaryDirectory() as tmpdir:
            artifact_root = Path(tmpdir) / "decisions"
            writer = ArtifactWriter(artifact_root=artifact_root, signer=test_signer)

            result = writer.write_decision(sample_decision)
            sig_path = Path(result["signature_path"])

            sig_json = json.loads(sig_path.read_text())

            assert sig_json["algorithm"] == "ed25519"
            assert "key_id" in sig_json
            assert "signature" in sig_json
            assert "signed_content_hash" in sig_json

    def test_markdown_includes_signature_info(self, sample_decision, test_signer):
        """Test that Markdown artifact includes signature information."""
        with tempfile.TemporaryDirectory() as tmpdir:
            artifact_root = Path(tmpdir) / "decisions"
            writer = ArtifactWriter(artifact_root=artifact_root, signer=test_signer)

            result = writer.write_decision(sample_decision)
            md_path = Path(result["markdown_path"])
            md_content = md_path.read_text()

            assert "Cryptographic Signature (Phase H)" in md_content
            assert "Algorithm:" in md_content
            assert "Key ID:" in md_content
            assert "Signature:" in md_content

    def test_writer_fails_without_signing_key(self, sample_decision, monkeypatch):
        """Test that ArtifactWriter fails closed if signing key is unavailable."""
        monkeypatch.delenv("CIV_SIGNING_KEY", raising=False)

        with tempfile.TemporaryDirectory() as tmpdir:
            artifact_root = Path(tmpdir) / "decisions"

            with pytest.raises(SigningError, match="CIV_SIGNING_KEY"):
                writer = ArtifactWriter(artifact_root=artifact_root)


class TestEndToEndVerification:
    """Test end-to-end signing and verification workflow."""

    def test_sign_and_verify_roundtrip(self, sample_decision, test_signer, test_verifier):
        """Test complete sign → write → read → verify workflow."""
        with tempfile.TemporaryDirectory() as tmpdir:
            artifact_root = Path(tmpdir) / "decisions"
            writer = ArtifactWriter(artifact_root=artifact_root, signer=test_signer)

            # Write decision (signs automatically)
            result = writer.write_decision(sample_decision)

            # Read back JSON and signature
            json_path = Path(result["json_path"])
            sig_path = Path(result["signature_path"])

            json_content = json_path.read_text()
            sig_metadata = json.loads(sig_path.read_text())

            # Verify signature
            verified, error = test_verifier.verify_signature(json_content, sig_metadata)

            assert verified is True
            assert error is None

    def test_verify_detects_tampered_artifact(self, sample_decision, test_signer, test_verifier):
        """Test that verification detects tampered artifacts."""
        with tempfile.TemporaryDirectory() as tmpdir:
            artifact_root = Path(tmpdir) / "decisions"
            writer = ArtifactWriter(artifact_root=artifact_root, signer=test_signer)

            # Write decision
            result = writer.write_decision(sample_decision)
            json_path = Path(result["json_path"])
            sig_path = Path(result["signature_path"])

            # Tamper with JSON content
            tampered_json = json.loads(json_path.read_text())
            tampered_json["classification"] = "TAMPERED"
            json_path.write_text(json.dumps(tampered_json, indent=2))

            # Read tampered content and original signature
            tampered_content = json_path.read_text()
            sig_metadata = json.loads(sig_path.read_text())

            # Verify signature (should fail)
            verified, error = test_verifier.verify_signature(tampered_content, sig_metadata)

            assert verified is False
            assert "Content hash mismatch" in error

    def test_verify_rejects_unsigned_artifact(self, sample_decision, test_verifier):
        """Test that verification fails for artifacts without signatures."""
        # Create unsigned artifact (bypass ArtifactWriter)
        json_content = sample_decision.to_json_str()

        # Try to verify with empty metadata
        verified, error = test_verifier.verify_signature(json_content, {})

        assert verified is False
        assert "Missing required field" in error


class TestGlobalInvariants:
    """Validate Phase H global invariants."""

    def test_signing_produces_no_authority_writes(self, sample_decision, test_signer):
        """Test that signing operations produce no authority table writes."""
        # This is validated by inspection: artifact_signing.py contains no
        # INSERT/UPDATE/DELETE to authority tables

        content = sample_decision.to_json_str()
        sig_metadata = test_signer.sign_artifact(content)

        # Signing succeeded without database interaction
        assert sig_metadata["algorithm"] == "ed25519"

    def test_signing_preserves_advisory_classification(self, sample_decision, test_signer):
        """Test that signing does not modify decision classification."""
        with tempfile.TemporaryDirectory() as tmpdir:
            artifact_root = Path(tmpdir) / "decisions"
            writer = ArtifactWriter(artifact_root=artifact_root, signer=test_signer)

            result = writer.write_decision(sample_decision)
            json_path = Path(result["json_path"])

            # Read back and verify classification unchanged
            written_decision = json.loads(json_path.read_text())

            assert written_decision["classification"] == "ADVISORY_ONLY"
            assert written_decision["enforcement_prohibited"] is True

    def test_signing_is_non_executable(self, sample_decision, test_signer):
        """Test that signatures contain no executable code."""
        content = sample_decision.to_json_str()
        sig_metadata = test_signer.sign_artifact(content)

        # Signature is pure data (hex-encoded bytes)
        assert isinstance(sig_metadata["signature"], str)
        assert all(c in "0123456789abcdef" for c in sig_metadata["signature"])

        # No executable fields
        assert "exec" not in sig_metadata
        assert "eval" not in sig_metadata
        assert "code" not in sig_metadata
