# =============================================================================
# ThreadForge — Ledger Seal Chain
# Fully deterministic SHA3-512 chain-of-custody sealer
# runtime/ledger/seal.py
# =============================================================================

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import ROUND_HALF_EVEN, Decimal
from typing import Any

from runtime.identity.capabilities import CapabilitySet
from runtime.identity.context import IdentityContext


def _compute_schema_hash(schema_data: Any) -> str:
    """Compute SHA3-512 hash of schema data for versioning."""
    canonical_json = json.dumps(schema_data, sort_keys=True, separators=(",", ":"))
    hash_obj = hashlib.sha3_512()
    hash_obj.update(canonical_json.encode("utf-8"))
    return f"sha3-512:{hash_obj.hexdigest()}"


@dataclass(frozen=True)
class AuthorityDenial:
    """Tier 1.75: Cryptographic proof of authority denial.

    Every denial MUST emit a sealed denial record for auditability.
    """

    identity_id: str
    requested_capability: str
    denial_reason_code: str  # NO_CAPABILITY, DELEGATION_EXPIRED, SCOPE_VIOLATION, etc.
    policy_hash: str
    timestamp: datetime
    nonce: str
    denial_seal: str  # SHA3-512 hash

    DENIAL_REASONS = {
        "NO_CAPABILITY",
        "DELEGATION_EXPIRED",
        "SCOPE_VIOLATION",
        "POLICY_MISMATCH",
        "IDENTITY_INVALID",
        "REPLAY_ATTEMPT",
        "NO_ACTIVE_AAS",  # Phase 1.2: AAS enforcement denial
        "ESCALATION_REQUIRED",  # Phase 8: Governance escalation
    }

    @classmethod
    def create(
        cls,
        identity_id: str,
        requested_capability: str,
        denial_reason: str,
        policy_hash: str,
        nonce: str,
    ) -> AuthorityDenial:
        """Create a sealed authority denial record."""
        if denial_reason not in cls.DENIAL_REASONS:
            raise ValueError(f"Invalid denial reason: {denial_reason}")

        denial_data = {
            "identity_id": identity_id,
            "requested_capability": requested_capability,
            "denial_reason_code": denial_reason,
            "policy_hash": policy_hash,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "nonce": nonce,
        }

        canonical_json = json.dumps(denial_data, sort_keys=True, separators=(",", ":"))
        hash_obj = hashlib.sha3_512()
        hash_obj.update(canonical_json.encode("utf-8"))
        denial_seal = f"sha3-512:{hash_obj.hexdigest()}"

        return cls(
            identity_id=identity_id,
            requested_capability=requested_capability,
            denial_reason_code=denial_reason,
            policy_hash=policy_hash,
            timestamp=datetime.now(timezone.utc),
            nonce=nonce,
            denial_seal=denial_seal,
        )


@dataclass(frozen=True)
class AuthoritySeal:
    """Immutable cryptographic seal of authority context.

    Phase 10: Cryptographic Authority Sealing
    Captures the complete authority state at decision time.

    Tier 1.75: Versioned seals with schema integrity.
    """

    spiffe_id: str
    trust_domain: str
    effective_capabilities: frozenset[str]
    active_delegation_ids: frozenset[str]
    governing_policy_hash: str
    decision_outcome: str
    timestamp: datetime
    plan_hash: str

    # Tier 1.75: Authority Seal Versioning
    seal_version: int = 1  # Monotonic version number
    identity_schema_hash: str = ""  # SHA3-512 of identity schema
    policy_bundle_hash: str = ""  # SHA3-512 of policy bundle
    capability_schema_hash: str = ""  # SHA3-512 of capability schema
    delegation_schema_hash: str = ""  # SHA3-512 of delegation schema

    def as_dict(self) -> dict[str, Any]:
        """Canonical dictionary representation for hashing."""
        return {
            "spiffe_id": self.spiffe_id,
            "trust_domain": self.trust_domain,
            "effective_capabilities": sorted(self.effective_capabilities),
            "active_delegation_ids": sorted(self.active_delegation_ids),
            "governing_policy_hash": self.governing_policy_hash,
            "decision_outcome": self.decision_outcome,
            "timestamp": self.timestamp.isoformat(),
            "plan_hash": self.plan_hash,
            # Tier 1.75: Include versioning metadata
            "seal_version": self.seal_version,
            "identity_schema_hash": self.identity_schema_hash,
            "policy_bundle_hash": self.policy_bundle_hash,
            "capability_schema_hash": self.capability_schema_hash,
            "delegation_schema_hash": self.delegation_schema_hash,
        }

    @classmethod
    def create(
        cls,
        identity: IdentityContext,
        effective_capabilities: CapabilitySet,
        governing_policy_hash: str,
        decision_outcome: str,
        plan_hash: str,
    ) -> AuthoritySeal:
        """Create an authority seal from governance context.

        Phase 10: Sealing happens AFTER governance enforcement.
        Tier 1.75: Includes schema versioning for anti-downgrade protection.
        """
        # Lazy import to avoid circular dependency
        from runtime.identity.delegation_store import get_delegation_store

        # Get active delegation IDs for this identity
        store = get_delegation_store()
        active_delegations = store.get_active_delegations_for_delegate(identity.spiffe_id)
        delegation_ids = frozenset(d.delegation_id for d in active_delegations)

        # Tier 1.75: Compute schema hashes for versioning
        identity_schema = {
            "version": "1.0",
            "fields": ["spiffe_id", "trust_domain", "tier", "namespace", "service_account", "attested"],
        }
        policy_schema = {"version": "1.0", "decision_types": ["ALLOW", "DENY", "ESCALATE"]}
        capability_schema = {"version": "1.0", "types": ["s3:GetObject", "s3:PutObject", "governance.evaluate"]}
        delegation_schema = {
            "version": "1.0",
            "fields": ["delegation_id", "delegate_spiffe_id", "capabilities", "valid_from", "valid_until"],
        }

        return cls(
            spiffe_id=identity.spiffe_id,
            trust_domain=identity.trust_domain,
            effective_capabilities=frozenset(effective_capabilities.capabilities),
            active_delegation_ids=delegation_ids,
            governing_policy_hash=governing_policy_hash,
            decision_outcome=decision_outcome,
            timestamp=datetime.now(timezone.utc),
            plan_hash=plan_hash,
            # Tier 1.75: Schema versioning
            seal_version=1,
            identity_schema_hash=_compute_schema_hash(identity_schema),
            policy_bundle_hash=_compute_schema_hash(policy_schema),
            capability_schema_hash=_compute_schema_hash(capability_schema),
            delegation_schema_hash=_compute_schema_hash(delegation_schema),
        )

    def compute_hash(self) -> str:
        """Compute deterministic cryptographic hash of the seal."""
        seal_dict = self.as_dict()
        canonical_json = json.dumps(seal_dict, sort_keys=True, separators=(",", ":"))
        hash_obj = hashlib.sha3_512()
        hash_obj.update(canonical_json.encode("utf-8"))
        return f"sha3-512:{hash_obj.hexdigest()}"


# Deterministic, stateless sealer
GENESIS = "GENESIS"


def _canonicalize_value(v: Any) -> Any:
    """Canonicalize values for deterministic sealing.

    Rules:
    - ints remain ints
    - floats become Decimal with fixed precision (9 places) and then stringified to avoid cross-language float nuances
    - dicts: keys sorted, values canonicalized recursively
    - lists: canonicalize elements in order
    - timestamps (floats) should be converted by caller to integer ms
    """
    if isinstance(v, float):
        d = Decimal(str(v)).quantize(Decimal("1.000000000"), rounding=ROUND_HALF_EVEN)
        return format(d, "f")
    if isinstance(v, int):
        return v
    if isinstance(v, dict):
        return {k: _canonicalize_value(v[k]) for k in sorted(v.keys())}
    if isinstance(v, list):
        return [_canonicalize_value(x) for x in v]
    return v


def _canonicalize_unsealed(unsealed: dict[str, Any]) -> dict[str, Any]:
    """Produce a canonical, typed, and ordered dict for sealing.

    This selects explicit fields and normalizes their types (e.g., timestamps to ms).
    """
    # Only include a whitelisted set of fields in a defined order
    fields = [
        "ts",
        "trace_id",
        "sender",
        "recipient",
        "op",
        "priority",
        "reflex_verdict",
        "truth_verdict",
        "backend",
        "status",
        "payload",
        "result",
        "duration_ms",
        "identity",
        "capabilities",
    ]

    out: dict[str, Any] = {}

    # Normalize timestamp -> integer milliseconds
    ts = unsealed.get("ts")
    if isinstance(ts, (int,)):
        out["ts"] = int(ts) * 1000
    elif isinstance(ts, float):
        out["ts"] = int(ts * 1000)
    else:
        # if missing, set 0
        out["ts"] = 0

    for f in fields[1:]:
        val = unsealed.get(f)
        if f == "payload" or f == "result":
            out[f] = _canonicalize_value(val or {})
        elif f == "identity":
            if val and isinstance(val, dict):
                # include a restricted set of identity fields only
                out["identity"] = {
                    "spiffe_id": val.get("spiffe_id"),
                    "trust_domain": val.get("trust_domain"),
                    "attested": bool(val.get("attested", False)),
                }
            elif val:
                out["identity"] = {
                    "spiffe_id": val.spiffe_id,
                    "trust_domain": val.trust_domain,
                    "attested": bool(getattr(val, "attested", False)),
                }
            else:
                out["identity"] = None
        else:
            out[f] = _canonicalize_value(val)

    return out


def compute_entry_seal(
    unsealed_entry_dict: dict[str, Any],
    prev_seal: str,
    identity_hash: str,
    policy_hash: str | None = None,
) -> str:
    """Compute deterministic seal for an entry using explicit prev_seal and identity_hash.

    Seal input invariant (order sensitive, canonical JSON used for payload):
      payload_hash = sha3-512(canonical_json(payload))
      material = (
        canonical_json(canonical_unsealed) + "|" + prev_seal + "|" + payload_hash + "|" + identity_hash
        + ("|" + policy_hash if policy_hash else "")
      )
      seal = sha3-512(material)

    Returns value with algorithm prefix: sha3-512:<hex>
    """
    if prev_seal is None:
        raise ValueError("prev_seal must be provided (use 'GENESIS' for first entry)")
    if not identity_hash:
        raise ValueError("identity_hash is required for authoritative sealing")

    canonical_unsealed = _canonicalize_unsealed(unsealed_entry_dict)

    # payload hash
    payload = canonical_unsealed.get("payload", {})
    payload_canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    payload_hash_obj = hashlib.sha3_512()
    payload_hash_obj.update(payload_canonical.encode("utf-8"))
    payload_hash = f"sha3-512:{payload_hash_obj.hexdigest()}"

    canonical_json = json.dumps(canonical_unsealed, sort_keys=True, separators=(",", ":"))
    m = hashlib.sha3_512()
    prev = str(prev_seal)
    material = canonical_json + "|" + prev + "|" + payload_hash + "|" + identity_hash
    if policy_hash:
        material = material + "|" + policy_hash
    m.update(material.encode("utf-8"))
    return f"sha3-512:{m.hexdigest()}"


# Backwards-compatible helper: streaming verifier that keeps last_seal in-memory.
# NOTE: This class is provided for offline verification of existing ledger files.
# New code paths MUST use compute_entry_seal with an explicit prev_seal instead.
class LedgerSealChain:
    def __init__(self):
        self.last_seal = None

    def seal(self, entry_dict: dict) -> str:
        """Legacy-friendly sealing helper.

        When invoked without an explicit identity_hash (legacy path), derive a
        deterministic synthetic identity_hash from the entry contents so the
        legacy sealer remains deterministic and non-authoritative.
        """
        prev = self.last_seal or GENESIS
        # Use explicit identity_hash if present in entry, else derive a synthetic hash
        identity_hash = entry_dict.get("identity_hash") if isinstance(entry_dict, dict) else None
        if not identity_hash:
            # Deterministically derive from canonical JSON of the entry
            h = hashlib.sha3_512()
            h.update(json.dumps(entry_dict, sort_keys=True, separators=(",", ":")).encode("utf-8"))
            identity_hash = f"sha3-512:{h.hexdigest()}"

        s = compute_entry_seal(entry_dict, prev, identity_hash)
        self.last_seal = s
        return s
