"""Allowed Action Set — Governance-Emitted Authorization Envelope

Phase 1: Governance Loop Closure

This module defines the Allowed Action Set (AAS), which is the output of
governance evaluation based on Civ intelligence. The AAS is:

- Declarative (no logic, just data)
- Immutable per evaluation
- Time-bounded (valid_until timestamp)
- Identity-scoped (allowed_identities list)
- Action-explicit (allowed_actions list)
- Causality-linked (derived_from_decision_id)
- Auditable (provenance_hash)

Global Invariant: This module SHALL NOT execute actions, flip enforcement
flags, or modify cluster state. It ONLY defines authorization envelopes
that enforcement points can verify.

Causality Chain:

Signal → Civ DecisionRecord → Governance Evaluation → AAS → Enforcement Check

Each AAS is linked to the Civ DecisionRecord that informed it via
derived_from_decision_id, ensuring full traceability.
"""

import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import TYPE_CHECKING, Any, Dict, List, Optional
from uuid import UUID, uuid4

if TYPE_CHECKING:
    from runtime.civ.provenance.decision_record import DecisionRecord, DecisionType


@dataclass(frozen=True)
class AllowedActionSet:
    """Allowed Action Set — Authorization envelope emitted by governance.

    Properties:
    - aas_id: Unique identifier for this AAS
    - derived_from_decision_id: Links to Civ DecisionRecord.decision_id
    - generated_at: Timestamp when AAS was created
    - valid_until: Time-bounded authority (after this, AAS is invalid)
    - scope: Explicit scope (namespace, cluster, resource type)
    - allowed_actions: List of permitted actions (e.g., ["vector.write", "storage.read"])
    - allowed_identities: List of SPIFFE IDs permitted to execute actions
    - budget_constraints: Optional constraints from Civ metrics
    - denial_constraints: Optional constraints from Civ metrics
    - provenance_hash: Deterministic hash over inputs for auditability
    """

    aas_id: UUID
    derived_from_decision_id: UUID
    generated_at: datetime
    valid_until: datetime
    scope: Dict[str, str]  # {"namespace": "...", "cluster": "...", "resource_type": "..."}
    allowed_actions: List[str]  # ["vector.write", "storage.read", "kernel.execute"]
    allowed_identities: List[str]  # ["spiffe://<SPIFFE_TRUST_DOMAIN>/ns/workload-prod/sa/batch-worker"]
    budget_constraints: Dict[str, float] = field(default_factory=dict)  # {"max_utilization": 0.9}
    denial_constraints: Dict[str, float] = field(default_factory=dict)  # {"max_denial_pressure": 0.8}
    provenance_hash: str = ""
    signature: str = field(default="")  # Phase 7: Ed25519 signature (hex-encoded)
    signing_key_id: str = field(default="governance-signer-v1")  # Phase 7: Key ID for rotation
    ccid: str = field(default="")  # Phase 8: Causal Correlation ID (for observability)

    def __post_init__(self):
        """Validate AAS properties."""
        if self.generated_at >= self.valid_until:
            raise ValueError(f"generated_at ({self.generated_at}) must be before valid_until ({self.valid_until})")

        if not self.allowed_actions:
            raise ValueError("allowed_actions cannot be empty")

        if not self.allowed_identities:
            raise ValueError("allowed_identities cannot be empty")

        # Compute provenance hash if not provided
        if not self.provenance_hash:
            object.__setattr__(self, "provenance_hash", self._compute_provenance_hash())

    def canonical_form(self) -> str:
        """Produce canonical JSON for cryptographic signing.

        Deterministic JSON representation using sorted keys and no whitespace.
        Same input always produces identical output, enabling signature verification.

        Returns:
            Canonical JSON string suitable for Ed25519 signing
        """
        payload = {
            "aas_id": str(self.aas_id),
            "derived_from_decision_id": str(self.derived_from_decision_id),
            "generated_at": self.generated_at.isoformat(),
            "valid_until": self.valid_until.isoformat(),
            "scope": self.scope,
            "allowed_actions": sorted(self.allowed_actions),
            "allowed_identities": sorted(self.allowed_identities),
            "budget_constraints": self.budget_constraints,
            "denial_constraints": self.denial_constraints,
            "provenance_hash": self.provenance_hash,
        }

        # Deterministic JSON: sorted keys, no extra whitespace
        return json.dumps(payload, sort_keys=True, separators=(",", ":"))

    def _compute_provenance_hash(self) -> str:
        """Compute deterministic hash over AAS inputs."""
        hash_input = {
            "derived_from_decision_id": str(self.derived_from_decision_id),
            "generated_at": self.generated_at.isoformat(),
            "valid_until": self.valid_until.isoformat(),
            "scope": self.scope,
            "allowed_actions": sorted(self.allowed_actions),
            "allowed_identities": sorted(self.allowed_identities),
            "budget_constraints": self.budget_constraints,
            "denial_constraints": self.denial_constraints,
        }
        canonical_json = json.dumps(hash_input, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(canonical_json.encode("utf-8")).hexdigest()

    def to_dict(self) -> Dict[str, Any]:
        """Convert AAS to dictionary for serialization."""
        return {
            "aas_id": str(self.aas_id),
            "derived_from_decision_id": str(self.derived_from_decision_id),
            "generated_at": self.generated_at.isoformat(),
            "valid_until": self.valid_until.isoformat(),
            "scope": self.scope,
            "allowed_actions": self.allowed_actions,
            "allowed_identities": self.allowed_identities,
            "budget_constraints": self.budget_constraints,
            "denial_constraints": self.denial_constraints,
            "provenance_hash": self.provenance_hash,
            "signature": self.signature,
            "signing_key_id": self.signing_key_id,
            "ccid": self.ccid,
        }

    def is_valid(self, current_time: Optional[datetime] = None) -> bool:
        """Check if AAS is currently valid (not expired)."""
        if current_time is None:
            current_time = datetime.now()
        return current_time <= self.valid_until

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "AllowedActionSet":
        """Reconstruct AllowedActionSet from dictionary.

        Phase 7: Validates signature format if present (will be enforced on load).

        Args:
            data: Dictionary representation of AAS

        Returns:
            AllowedActionSet instance
        """
        # Phase 7: Validate signature format if present
        signature = data.get("signature", "")
        if signature and not isinstance(signature, str):
            raise ValueError(f"Invalid signature type: {type(signature)}")
        if signature and (len(signature) != 128 or not all(c in "0123456789abcdef" for c in signature)):
            raise ValueError(f"Invalid signature format: {signature}")

        aas = cls(
            aas_id=UUID(data["aas_id"]),
            derived_from_decision_id=UUID(data["derived_from_decision_id"]),
            generated_at=datetime.fromisoformat(data["generated_at"]),
            valid_until=datetime.fromisoformat(data["valid_until"]),
            scope=data["scope"],
            allowed_actions=data["allowed_actions"],
            allowed_identities=data["allowed_identities"],
            budget_constraints=data.get("budget_constraints", {}),
            denial_constraints=data.get("denial_constraints", {}),
        )

        # Set signature and signing_key_id if present
        if signature:
            object.__setattr__(aas, "signature", signature)
        if "signing_key_id" in data:
            object.__setattr__(aas, "signing_key_id", data["signing_key_id"])

        return aas

    def allows_action(self, action: str) -> bool:
        """Check if action is in allowed_actions list."""
        return action in self.allowed_actions

    def allows_identity(self, spiffe_id: str) -> bool:
        """Check if identity is in allowed_identities list."""
        return spiffe_id in self.allowed_identities


class AASBuilder:
    """Builder for constructing AllowedActionSet from Civ DecisionRecord.

    This class contains the mapping logic from Civ intelligence outputs
    to governance authorization envelopes.

    Mapping Strategy:
    - DecisionRecord.decision_type → action permissions
    - DecisionRecord.dominant_contributors → allowed_identities
    - DecisionRecord.derived_metrics → constraints
    - DecisionRecord.time_window → validity period
    """

    @staticmethod
    def from_decision_record(
        decision: "DecisionRecord",
        validity_duration: timedelta = timedelta(hours=1),
        override_actions: Optional[List[str]] = None,
        override_identities: Optional[List[str]] = None,
    ) -> AllowedActionSet:
        """Build AAS from Civ DecisionRecord.

        Args:
            decision: Civ DecisionRecord artifact
            validity_duration: How long AAS is valid (default: 1 hour)
            override_actions: Explicit action list (if None, derived from decision_type)
            override_identities: Explicit identity list (if None, derived from contributors)

        Returns:
            AllowedActionSet ready for enforcement checks
        """

        # Determine allowed actions based on decision type
        if override_actions is not None:
            allowed_actions = override_actions
        else:
            allowed_actions = AASBuilder._derive_actions_from_decision_type(decision.decision_type)

        # Extract allowed identities from dominant contributors
        if override_identities is not None:
            allowed_identities = override_identities
        else:
            allowed_identities = [
                contrib.contributor_id
                for contrib in decision.dominant_contributors
                if contrib.contributor_id.startswith("spiffe://")
            ]

            # Fallback: if no SPIFFE identities found, deny all (empty list)
            if not allowed_identities:
                allowed_identities = []

        # Extract scope from decision inputs
        scope = {
            "cluster": "threadforge",  # Could be derived from decision.inputs.parameters
            "namespace": decision.inputs.parameters.get("namespace", "default"),
            "resource_type": "memory",  # Could be derived from decision_type
        }

        # Extract constraints from derived metrics
        budget_constraints = {
            "max_utilization": min(1.0, decision.derived_metrics.utilization_percent / 100.0 + 0.1),
        }

        denial_constraints = {
            "max_denial_pressure": min(1.0, decision.derived_metrics.denial_pressure + 0.1),
        }

        # Time-bound authority
        generated_at = datetime.now()
        valid_until = generated_at + validity_duration

        # Build AAS
        aas = AllowedActionSet(
            aas_id=uuid4(),
            derived_from_decision_id=decision.decision_id,
            generated_at=generated_at,
            valid_until=valid_until,
            scope=scope,
            allowed_actions=allowed_actions,
            allowed_identities=allowed_identities,
            budget_constraints=budget_constraints,
            denial_constraints=denial_constraints,
        )

        return aas

    @staticmethod
    def _derive_actions_from_decision_type(decision_type: "DecisionType") -> List[str]:
        """Map Civ decision type to allowed actions.

        This is a policy decision: what actions are safe given the decision context?

        - BUDGET_PRESSURE: Allow read-only operations
        - POLICY_PRESSURE: Allow limited operations
        - DENIAL_PRESSURE: Allow very limited operations
        - COMPOSITE: Most restrictive union
        """
        from runtime.civ.provenance.decision_record import DecisionType

        if decision_type == DecisionType.BUDGET_PRESSURE:
            # Budget pressure: allow reads, deny writes
            # Include both canonical and legacy action names to maintain compatibility
            return ["vector.search", "vector.read", "storage.read"]

        if decision_type == DecisionType.POLICY_PRESSURE:
            # Policy pressure: allow reads, limited writes
            return [
                "vector.search",
                "vector.read",
                "vector.insert",
                "vector.delete",
                "vector.embed",
                "storage.read",
                "storage.write",
            ]

        if decision_type == DecisionType.DENIAL_PRESSURE:
            # Denial pressure: read-only
            return ["vector.search", "vector.read", "storage.read"]

        if decision_type == DecisionType.COMPOSITE:
            # Composite: most restrictive (read-only)
            return ["vector.search", "vector.read", "storage.read"]

        # Unknown: deny all
        return []


class AASWriter:
    """Writer for persisting AllowedActionSet artifacts to disk.

    AAS artifacts are written for audit and replay, not for runtime consumption.
    Enforcement checks use in-memory AAS objects, not filesystem reads.
    """

    @staticmethod
    def write(aas: AllowedActionSet, artifact_dir: str = "artifacts/aas") -> str:
        """Write AAS to JSON file.

        Args:
            aas: AllowedActionSet to persist
            artifact_dir: Directory for AAS artifacts

        Returns:
            Path to written file
        """
        import os

        os.makedirs(artifact_dir, exist_ok=True)

        filename = f"{aas.aas_id}.json"
        filepath = os.path.join(artifact_dir, filename)

        with open(filepath, "w") as f:
            json.dump(aas.to_dict(), f, indent=2)

        return filepath


def log_aas_causality(
    aas: AllowedActionSet,
    decision_provenance_hash: str,
    enforcement_outcome: str,
    action: str,
    identity: str,
) -> Dict[str, Any]:
    """Generate causality log entry linking Signal → Civ → AAS → Enforcement.

    Phase 7: Uses TamperEvidenceLog (HMAC/hash-chain) instead of plain JSONL.
    Each entry includes prev_hmac from previous entry for detection of tampering.

    This function produces a structured log entry that preserves the full
    causality chain for audit replay and is protected against tampering.

    Args:
        aas: AllowedActionSet used for enforcement check
        decision_provenance_hash: Civ DecisionRecord.provenance_hash
        enforcement_outcome: "allow" | "deny"
        action: Action that was checked
        identity: SPIFFE ID that attempted action

    Returns:
        Dict suitable for JSON logging (includes HMAC fields for integrity)
    """
    from runtime.governance.crypto_integrity import get_tamper_log

    entry = {
        "event": "governance.aas_enforcement",
        "aas_id": str(aas.aas_id),
        "decision_id": str(aas.derived_from_decision_id),
        "decision_provenance_hash": decision_provenance_hash,
        "aas_provenance_hash": aas.provenance_hash,
        "action": action,
        "identity": identity,
        "outcome": enforcement_outcome,
        "scope": aas.scope,
        "timestamp": datetime.now().isoformat(),
        "valid_until": aas.valid_until.isoformat(),
        "causality_chain": {
            "signal": "observability_metrics",
            "civ_decision": decision_provenance_hash,
            "aas": aas.provenance_hash,
            "enforcement": enforcement_outcome,
        },
        # Phase 7: Signature binding for cryptographic causality
        "aas_signature": getattr(aas, "signature", ""),
    }

    # Phase 7: Append to tamper-evident log (HMAC/hash-chain protected)
    tamper_log = get_tamper_log()
    tamper_log.append(entry)

    return entry
