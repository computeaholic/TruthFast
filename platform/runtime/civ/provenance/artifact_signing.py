"""
Artifact Signing — Cryptographic signing and verification for decision artifacts.

Phase H: Audit System Hardening

This module provides Ed25519 signing and verification for canonical decision
artifacts. All signatures are deterministic and verifiable offline.

Global Invariant: This module SHALL NOT write to authority tables, flip
enforcement flags, schedule execution, or emit executable signals.

Key Management:
- Private key: Loaded from environment variable CIV_SIGNING_KEY (hex-encoded)
- Public key: Derived from private key or loaded separately for verification
- Keys are Ed25519 (32-byte keys, 64-byte signatures)

Signature Format:
- Algorithm: Ed25519 (RFC 8032)
- Signature: 64 bytes (128 hex characters)
- Signed content: JSON artifact bytes (UTF-8 encoded)
- Detached signature (not embedded in signed content)
"""

import hashlib
import logging
import os
from typing import Optional, Tuple

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

logger = logging.getLogger(__name__)


class SigningError(Exception):
    """Raised when signing or verification fails."""

    pass


class ArtifactSigner:
    """
    Signs decision artifacts with Ed25519.

    Responsibilities:
    1. Load private key from environment or file
    2. Sign JSON artifact content
    3. Emit signature metadata (algorithm, key_id, signature)
    4. Fail closed if key is unavailable
    """

    def __init__(self, private_key: Optional[Ed25519PrivateKey] = None):
        """
        Initialize signer.

        Args:
            private_key: Ed25519PrivateKey. If None, loads from CIV_SIGNING_KEY env var.

        Raises:
            SigningError: If private key cannot be loaded
        """
        if private_key is None:
            private_key = self._load_private_key_from_env()

        self.private_key = private_key
        self.public_key = self.private_key.public_key()
        self.key_id = self._compute_key_id(self.public_key)
        self.logger = logging.getLogger(f"{__name__}.{self.__class__.__name__}")

    def _load_private_key_from_env(self) -> Ed25519PrivateKey:
        """
        Load Ed25519 private key from CIV_SIGNING_KEY environment variable.

        Returns:
            Ed25519PrivateKey

        Raises:
            SigningError: If key is missing or invalid
        """
        key_hex = os.environ.get("CIV_SIGNING_KEY")
        if not key_hex:
            raise SigningError(
                "CIV_SIGNING_KEY environment variable not set. " "Cannot sign artifacts without private key."
            )

        try:
            key_bytes = bytes.fromhex(key_hex)
        except ValueError as e:
            raise SigningError(f"CIV_SIGNING_KEY must be hex-encoded: {e}") from e

        if len(key_bytes) != 32:
            raise SigningError(f"CIV_SIGNING_KEY must be 32 bytes (64 hex chars), got {len(key_bytes)} bytes")

        try:
            return Ed25519PrivateKey.from_private_bytes(key_bytes)
        except Exception as e:
            raise SigningError(f"Invalid Ed25519 private key: {e}") from e

    def _compute_key_id(self, public_key: Ed25519PublicKey) -> str:
        """
        Compute key ID from public key (SHA256 hash of public key bytes).

        Args:
            public_key: Ed25519PublicKey

        Returns:
            Hex-encoded SHA256 hash of public key (first 16 chars)
        """
        pub_bytes = public_key.public_bytes_raw()
        key_hash = hashlib.sha256(pub_bytes).hexdigest()
        return key_hash[:16]  # First 16 hex chars for brevity

    def sign_artifact(self, artifact_content: str) -> dict:
        """
        Sign artifact content with Ed25519.

        Args:
            artifact_content: Artifact content (JSON string)

        Returns:
            Dict with signature metadata:
              - algorithm: "ed25519"
              - key_id: Key identifier (SHA256 hash prefix)
              - signature: Hex-encoded signature (128 hex chars)
              - signed_content_hash: SHA256 hash of signed content (for verification)

        Raises:
            SigningError: If signing fails
        """
        try:
            content_bytes = artifact_content.encode("utf-8")
            signature_bytes = self.private_key.sign(content_bytes)

            # Compute content hash for verification
            content_hash = hashlib.sha256(content_bytes).hexdigest()

            return {
                "algorithm": "ed25519",
                "key_id": self.key_id,
                "signature": signature_bytes.hex(),
                "signed_content_hash": content_hash,
            }
        except Exception as e:
            raise SigningError(f"Failed to sign artifact: {e}") from e

    def get_public_key_pem(self) -> str:
        """
        Get public key in PEM format for distribution.

        Returns:
            PEM-encoded public key string
        """
        from cryptography.hazmat.primitives import serialization

        pem_bytes = self.public_key.public_bytes(
            encoding=serialization.Encoding.PEM, format=serialization.PublicFormat.SubjectPublicKeyInfo
        )
        return pem_bytes.decode("utf-8")


class SignatureVerifier:
    """
    Verifies Ed25519 signatures on decision artifacts.

    Responsibilities:
    1. Load public key from environment, file, or provided key
    2. Verify signature against artifact content
    3. Detect tampering or unsigned artifacts
    4. Fail closed if verification fails
    """

    def __init__(self, public_key: Optional[Ed25519PublicKey] = None, public_key_pem: Optional[str] = None):
        """
        Initialize verifier.

        Args:
            public_key: Ed25519PublicKey. If None, loads from CIV_PUBLIC_KEY env var.
            public_key_pem: PEM-encoded public key string (alternative to public_key)

        Raises:
            SigningError: If public key cannot be loaded
        """
        if public_key is None and public_key_pem is None:
            public_key = self._load_public_key_from_env()
        elif public_key_pem is not None:
            public_key = self._load_public_key_from_pem(public_key_pem)

        self.public_key = public_key
        assert public_key is not None, "public_key must be provided or loadable from env"
        self.key_id = self._compute_key_id(public_key)
        self.logger = logging.getLogger(f"{__name__}.{self.__class__.__name__}")

    def _load_public_key_from_env(self) -> Ed25519PublicKey:
        """
        Load Ed25519 public key from CIV_PUBLIC_KEY environment variable.

        Returns:
            Ed25519PublicKey

        Raises:
            SigningError: If key is missing or invalid
        """
        key_hex = os.environ.get("CIV_PUBLIC_KEY")
        if not key_hex:
            raise SigningError(
                "CIV_PUBLIC_KEY environment variable not set. " "Cannot verify signatures without public key."
            )

        try:
            key_bytes = bytes.fromhex(key_hex)
        except ValueError as e:
            raise SigningError(f"CIV_PUBLIC_KEY must be hex-encoded: {e}") from e

        if len(key_bytes) != 32:
            raise SigningError(f"CIV_PUBLIC_KEY must be 32 bytes (64 hex chars), got {len(key_bytes)} bytes")

        try:
            return Ed25519PublicKey.from_public_bytes(key_bytes)
        except Exception as e:
            raise SigningError(f"Invalid Ed25519 public key: {e}") from e

    def _load_public_key_from_pem(self, pem_str: str) -> Ed25519PublicKey:
        """
        Load Ed25519 public key from PEM string.

        Args:
            pem_str: PEM-encoded public key

        Returns:
            Ed25519PublicKey

        Raises:
            SigningError: If PEM is invalid
        """
        from cryptography.hazmat.primitives import serialization

        try:
            pem_bytes = pem_str.encode("utf-8")
            public_key = serialization.load_pem_public_key(pem_bytes)

            if not isinstance(public_key, Ed25519PublicKey):
                raise SigningError(f"Expected Ed25519 public key, got {type(public_key)}")

            return public_key
        except Exception as e:
            raise SigningError(f"Invalid PEM public key: {e}") from e

    def _compute_key_id(self, public_key: Ed25519PublicKey) -> str:
        """
        Compute key ID from public key (SHA256 hash of public key bytes).

        Args:
            public_key: Ed25519PublicKey

        Returns:
            Hex-encoded SHA256 hash of public key (first 16 chars)
        """
        pub_bytes = public_key.public_bytes_raw()
        key_hash = hashlib.sha256(pub_bytes).hexdigest()
        return key_hash[:16]

    def verify_signature(self, artifact_content: str, signature_metadata: dict) -> Tuple[bool, Optional[str]]:
        """
        Verify Ed25519 signature on artifact content.

        Args:
            artifact_content: Artifact content (JSON string)
            signature_metadata: Dict with signature metadata:
              - algorithm: "ed25519"
              - key_id: Key identifier
              - signature: Hex-encoded signature
              - signed_content_hash: SHA256 hash of signed content

        Returns:
            Tuple of (verified: bool, error_message: Optional[str])
            - (True, None) if signature is valid
            - (False, error_message) if signature is invalid or verification fails

        Example:
            verified, error = verifier.verify_signature(json_str, sig_metadata)
            if not verified:
                raise SigningError(f"Signature verification failed: {error}")
        """
        # Validate signature metadata
        if not isinstance(signature_metadata, dict):
            return False, "Signature metadata must be a dictionary"

        required_fields = ["algorithm", "key_id", "signature", "signed_content_hash"]
        for field in required_fields:
            if field not in signature_metadata:
                return False, f"Missing required field in signature metadata: {field}"

        if signature_metadata["algorithm"] != "ed25519":
            return False, f"Unsupported algorithm: {signature_metadata['algorithm']}"

        if signature_metadata["key_id"] != self.key_id:
            return False, (f"Key ID mismatch: expected {self.key_id}, " f"got {signature_metadata['key_id']}")

        # Verify content hash
        content_bytes = artifact_content.encode("utf-8")
        content_hash = hashlib.sha256(content_bytes).hexdigest()

        if content_hash != signature_metadata["signed_content_hash"]:
            return False, (
                "Content hash mismatch: artifact has been tampered with or " "signature metadata does not match content"
            )

        # Verify signature
        try:
            signature_bytes = bytes.fromhex(signature_metadata["signature"])
        except ValueError:
            return False, "Signature must be hex-encoded"

        if len(signature_bytes) != 64:
            return False, f"Ed25519 signature must be 64 bytes, got {len(signature_bytes)}"

        try:
            if self.public_key is None:
                return False, "Verifier has no public key"
            self.public_key.verify(signature_bytes, content_bytes)
            return True, None
        except Exception as e:
            return False, f"Signature verification failed: {e}"

    # ------------------------------------------------------------------
    # New helper: verifies DecisionRecord payload signature
    def verify_decision_payload_signature(self, payload: dict) -> Tuple[bool, Optional[str]]:
        """Verify a DecisionRecord payload contains a valid signature.

        Expects the payload to be the dict produced by DecisionRecord.to_dict() and
        to contain the fields: 'signature', 'signing_key_id', 'algorithm', 'signed_content_hash'.

        Returns (True, None) on success; (False, message) on failure.
        """
        # Validate payload shape by attempting to reconstruct a DecisionRecord
        from runtime.civ.provenance.decision_record import DecisionRecord

        try:
            dr = DecisionRecord.from_dict(payload)
        except Exception as e:
            return False, f"Invalid DecisionRecord payload: {e}"

        # Build canonical content string
        content = dr.canonical_form()

        sig_meta = {
            "algorithm": payload.get("algorithm", "ed25519"),
            "key_id": payload.get("signing_key_id") or payload.get("signing_key_id", ""),
            "signature": payload.get("signature", ""),
            "signed_content_hash": payload.get("signed_content_hash", ""),
        }

        return self.verify_signature(content, sig_meta)
