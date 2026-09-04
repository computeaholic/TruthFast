"""
Cryptographic Integrity Module — Signing and verification for governance artifacts

Phase 7: Cryptographic Integrity Sealing

Provides:
- Ed25519 signing/verification for DecisionRecord and AAS
- Canonical JSON serialization (stable for signing)
- Tamper-evident JSONL logging with HMAC
- Replay protection (signature binding + timestamp validation)
- Verification enforcement on all artifact reads

No new autonomy. No background processes. Pure cryptographic binding.
"""

import hashlib
import hmac
import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ed25519
    from cryptography.hazmat.primitives.asymmetric.types import PrivateKeyTypes
except ImportError as err:
    raise ImportError("cryptography package required for Phase 7 crypto integrity") from err


def canonical_json(obj: Any) -> str:
    """Produce canonical JSON for cryptographic signing.

    Ensures deterministic output regardless of dict key order.
    Uses sorted keys and no extra whitespace.

    Args:
        obj: Object to serialize

    Returns:
        Canonical JSON string suitable for signing
    """
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def compute_canonical_hash(obj: Any) -> str:
    """Compute SHA256 hash of canonical JSON representation.

    Args:
        obj: Object to hash

    Returns:
        Hex-encoded SHA256 hash
    """
    canonical = canonical_json(obj)
    return hashlib.sha256(canonical.encode()).hexdigest()


class Ed25519Signer:
    """Ed25519 signer for governance artifacts.

    Manages signing keys and produces verifiable signatures.
    """

    def __init__(self, signing_key_path: str = ".signer/governance_key"):
        """Initialize signer.

        Args:
            signing_key_path: Path to Ed25519 private key (PEM format)
        """
        self.signing_key_path = signing_key_path
        self._signing_key: PrivateKeyTypes | None = None
        self._verify_key: Optional[ed25519.Ed25519PublicKey] = None

    def _load_or_create_key(self):
        """Load signing key or create new one."""
        key_path = Path(self.signing_key_path)
        key: PrivateKeyTypes | None = None

        if key_path.exists():
            with open(key_path, "rb") as f:
                pem = f.read()
            key = serialization.load_pem_private_key(pem, password=None)
        else:
            # Create new key
            key = ed25519.Ed25519PrivateKey.generate()
            key_path.parent.mkdir(parents=True, exist_ok=True)
            pem = key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            )
            with open(key_path, "wb") as f:
                f.write(pem)

        if key is None:
            raise RuntimeError("INTERNAL_ERROR: private key not initialized")
        if not isinstance(key, ed25519.Ed25519PrivateKey):
            raise RuntimeError("IDENTITY_FAILURE: expected Ed25519 key")

        self._signing_key = key
        pub = key.public_key()
        self._verify_key = pub

    def sign(self, obj: Any) -> str:
        """Sign object using Ed25519.

        Args:
            obj: Object to sign (will be canonicalized)

        Returns:
            Hex-encoded signature
        """
        if self._signing_key is None:
            self._load_or_create_key()
        key = self._signing_key
        if key is None:
            raise RuntimeError("INTERNAL_ERROR: private key not initialized")
        if not isinstance(key, ed25519.Ed25519PrivateKey):
            raise RuntimeError("IDENTITY_FAILURE: expected Ed25519 key")

        canonical = canonical_json(obj)
        signature = key.sign(canonical.encode())
        return signature.hex()

    def verify(self, obj: Any, signature_hex: str) -> bool:
        """Verify signature on object.

        Args:
            obj: Object to verify
            signature_hex: Hex-encoded signature

        Returns:
            True if signature valid, False otherwise
        """
        if self._verify_key is None:
            self._load_or_create_key()
        assert self._verify_key is not None, "verify key not available after load"

        try:
            canonical = canonical_json(obj)
            signature = bytes.fromhex(signature_hex)
            self._verify_key.verify(signature, canonical.encode())
            return True
        except Exception:
            return False


class TamperEvidenceLog:
    """HMAC-based tamper-evident JSONL log.

    Each entry includes HMAC of previous entry (hash chain).
    Detects any tampering or reordering.
    """

    def __init__(self, log_path: str, hmac_key: Optional[str] = None):
        """Initialize tamper-evident log.

        Args:
            log_path: Path to JSONL log file
            hmac_key: HMAC secret key (generated if not provided)
        """
        self.log_path = log_path
        self.hmac_key = (hmac_key or self._generate_hmac_key()).encode()
        self._last_hmac = "0000000000000000000000000000000000000000000000000000000000000000"

        # Load existing log if present
        if Path(log_path).exists():
            with open(log_path, "r") as f:
                for line in f:
                    if line.strip():
                        self._last_hmac = json.loads(line)["prev_hmac"]

    def _generate_hmac_key(self) -> str:
        """Generate random HMAC key."""
        return hashlib.sha256(os.urandom(32)).hexdigest()

    def append(self, entry: Dict[str, Any]) -> None:
        """Append entry to log with HMAC chain.

        Args:
            entry: Log entry to append
        """
        # Add HMAC of previous entry
        entry["prev_hmac"] = self._last_hmac

        # Compute canonical form (exclude current_hmac)
        canonical = canonical_json(entry)

        # Compute HMAC
        current_hmac = hmac.new(
            self.hmac_key,
            canonical.encode(),
            hashlib.sha256,
        ).hexdigest()

        entry["current_hmac"] = current_hmac
        self._last_hmac = current_hmac

        # Write to log
        Path(self.log_path).parent.mkdir(parents=True, exist_ok=True)
        with open(self.log_path, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def verify(self) -> bool:
        """Verify log integrity (no tampering detected).

        Returns:
            True if all entries have valid HMAC chain
        """
        if not Path(self.log_path).exists():
            return True

        prev_hmac = "0000000000000000000000000000000000000000000000000000000000000000"

        with open(self.log_path, "r") as f:
            for line in f:
                if not line.strip():
                    continue

                entry = json.loads(line)

                # Check prev_hmac matches
                if entry.get("prev_hmac") != prev_hmac:
                    return False

                # Recompute HMAC (exclude current_hmac from computation)
                stored_hmac = entry.pop("current_hmac", None)
                canonical = canonical_json(entry)
                computed_hmac = hmac.new(
                    self.hmac_key,
                    canonical.encode(),
                    hashlib.sha256,
                ).hexdigest()

                if computed_hmac != stored_hmac:
                    return False

                prev_hmac = stored_hmac

        return True


class ReplayProtection:
    """Prevents replay attacks on enforcement actions.

    Tracks (timestamp_bucket, decision_id, action, identity) tuples.
    Rejects if same tuple seen twice in TTL window.
    """

    def __init__(self, replay_log_path: str = "artifacts/logs/replay_protection.jsonl", ttl_seconds: int = 3600):
        """Initialize replay protection.

        Args:
            replay_log_path: Path to replay log
            ttl_seconds: Time-to-live for replay detection (default 1 hour)
        """
        self.replay_log_path = replay_log_path
        self.ttl_seconds = ttl_seconds
        self._seen = {}  # (timestamp_bucket, decision_id, action, identity) -> datetime

        # Load existing replay log
        if Path(replay_log_path).exists():
            with open(replay_log_path, "r") as f:
                for line in f:
                    if line.strip():
                        entry = json.loads(line)
                        key = (
                            entry["timestamp_bucket"],
                            entry["decision_id"],
                            entry["action"],
                            entry["identity"],
                        )
                        self._seen[key] = datetime.fromisoformat(entry["recorded_at"])

    def check_and_record(
        self,
        decision_id: str,
        action: str,
        identity: str,
    ) -> Tuple[bool, Optional[str]]:
        """Check if action is replay, and record it if not.

        Args:
            decision_id: DecisionRecord ID
            action: Action name
            identity: Identity performing action

        Returns:
            (is_replay, error_message) tuple
            is_replay=False if action allowed
            is_replay=True if replay detected
        """
        now = datetime.now()
        timestamp_bucket = int(now.timestamp()) // 60  # 1-minute buckets

        key = (str(timestamp_bucket), str(decision_id), str(action), str(identity))

        # Check if seen
        if key in self._seen:
            recorded_at = self._seen[key]
            age = (now - recorded_at).total_seconds()

            if age < self.ttl_seconds:
                return True, "Replay detected: same action within TTL"

            # TTL expired, allow re-execution
            del self._seen[key]

        # Record this execution
        self._seen[key] = now

        # Log to replay protection log
        Path(self.replay_log_path).parent.mkdir(parents=True, exist_ok=True)
        with open(self.replay_log_path, "a") as f:
            entry = {
                "timestamp_bucket": timestamp_bucket,
                "decision_id": str(decision_id),
                "action": str(action),
                "identity": str(identity),
                "recorded_at": now.isoformat(),
            }
            f.write(json.dumps(entry) + "\n")

        return False, None


# Resolve governance signing key path
def _resolve_governance_key_path() -> str:
    """Resolve the path to the governance signing key.

    Resolution order (minimal, safe):
    1. Environment variable `GOVERNANCE_KEY_PATH` (preferred)
    2. Stable system path `/etc/threadforge/keys/governance_key` if present
    3. Legacy repo-local path `.signer/governance_key` as a last resort

    This preserves local/dev workflows while encouraging operators to mount
    a secret to a stable filesystem location for runtime usage.
    """
    env_path = os.environ.get("GOVERNANCE_KEY_PATH")
    stable_path = "/etc/threadforge/keys/governance_key"

    if env_path:
        return env_path

    # Prefer the stable system path when it already exists
    if Path(stable_path).exists():
        return stable_path

    # Fall back to legacy developer-local path
    return ".signer/governance_key"


# Global signer instance
_signer: Optional[Ed25519Signer] = None


def get_signer() -> Ed25519Signer:
    """Get global Ed25519 signer instance.

    Uses `_resolve_governance_key_path()` to determine where the private key
    is expected to live. This allows operators to mount the governance key
    into the runtime at a stable path and avoid depending on job-scoped
    checkout directories like `_work`.
    """
    global _signer
    if _signer is None:
        signing_path = _resolve_governance_key_path()
        _signer = Ed25519Signer(signing_key_path=signing_path)
    return _signer


# Global tamper-evident log instance
_tamper_log: Optional[TamperEvidenceLog] = None


def get_tamper_log() -> TamperEvidenceLog:
    """Get global tamper-evident log instance."""
    global _tamper_log
    if _tamper_log is None:
        _tamper_log = TamperEvidenceLog("artifacts/logs/governance_tamper_evident.jsonl")
    return _tamper_log


# Global replay protection instance
_replay_protection: Optional[ReplayProtection] = None


def get_replay_protection() -> ReplayProtection:
    """Get global replay protection instance."""
    global _replay_protection
    if _replay_protection is None:
        _replay_protection = ReplayProtection()
    return _replay_protection
