"""AAS Provider — Wire Civ DecisionRecord → AllowedActionSet → Enforcement

Phase 1: Governance Loop Closure (Implementation Only)
Phase 6: Meta-Governance (Autonomy Constraint Enforcement)
Phase 7: Cryptographic Integrity Sealing
Phase 8: Latticed Observability (CCID binding)

This module wires existing components:
  - Consumes Civ DecisionRecord artifacts (already produced by ProvenanceBuilder)
  - Checks AutonomyConstraint before generating AAS (Phase 6)
  - Generates AllowedActionSet (using existing AASBuilder)
  - Signs AAS with Ed25519 before caching (Phase 7)
  - Computes CCID and emits causal signals (Phase 8)
  - Provides AAS lookup for enforcement checks
  - Enforces signature verification on artifact reads (Phase 7)
  - Applies replay protection on enforcement (Phase 7)

NO new abstractions. NO schedulers. NO background processes.

Causality Chain (Required):

    Signal (metrics)
    → Civ ProvenanceBuilder
    → DecisionRecord (artifact)
    → [Phase 7: Sign DecisionRecord]
    → [Phase 6: Check AutonomyConstraint]
    → AASProvider.generate_aas_from_decision()
    → AllowedActionSet (in-memory, signed)
    → [Phase 7: Sign AAS]
    → [Phase 7: Check replay protection]
    → enforce_with_aas()
    → allow/deny

Meta-Governance Causality:

    AAS artifacts
    → MetaCivProvider (trend analysis)
    → MetaDecisionRecord
    → AutonomyConstraint (operator-set)
    → Enforcement (checks constraint before AAS generation)

Global Invariant: This module does NOT execute actions. It only generates
authorization envelopes that enforcement points verify.
"""

import json
import os
import threading
from collections import OrderedDict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional
from uuid import UUID

from runtime.civ.provenance.decision_record import DecisionRecord
from runtime.governance.allowed_action_set import AASBuilder, AASWriter, AllowedActionSet, log_aas_causality
from runtime.governance.autonomy_constraint import get_autonomy_constraint_manager
from runtime.governance.crypto_integrity import get_replay_protection, get_signer
from internal.observability.causal_correlation import compute_ccid, emit_causal_log, emit_causal_metric


def log_aas_generation(decision_id, decision_type: str, provenance_hash: str) -> None:
    """Log AAS generation from Civ DecisionRecord.

    Records: Civ DecisionRecord -> Governance -> AAS generation.
    Validates inputs to prevent log injection attacks.
    """
    import json
    import os
    from datetime import datetime

    # Prevent log injection via newlines
    if "\n" in decision_type or "\r" in decision_type:
        raise ValueError("Newlines not allowed in decision_type")
    if "\n" in provenance_hash or "\r" in provenance_hash:
        raise ValueError("Newlines not allowed in provenance_hash")

    log_entry = {
        "event": "governance.aas_generation",
        "decision_id": str(decision_id),
        "decision_type": decision_type,
        "decision_provenance_hash": provenance_hash,
        "timestamp": datetime.now().isoformat(),
        "causality_stage": "civ_to_governance",
    }

    os.makedirs("artifacts/logs", exist_ok=True)
    with open("artifacts/logs/governance_aas.jsonl", "a") as f:
        f.write(json.dumps(log_entry) + "\n")


# Global singleton instance
_global_aas_provider: Optional["AASProvider"] = None
_global_aas_provider_lock = threading.Lock()


def get_aas_provider() -> "AASProvider":
    """Get the global singleton AASProvider instance.

    This ensures AAS cache is shared across all requests within a process.
    The singleton loads AAS artifacts on first access.
    """
    global _global_aas_provider

    if _global_aas_provider is None:
        with _global_aas_provider_lock:
            if _global_aas_provider is None:
                _global_aas_provider = AASProvider()
                # Load existing AAS artifacts on startup
                _global_aas_provider.load_aas_from_artifacts()

    return _global_aas_provider


class AASProvider:
    """Provider for generating and retrieving AllowedActionSet from Civ DecisionRecord.

    This class wires existing components:
      - Reads DecisionRecord artifacts from disk (written by Civ ArtifactWriter)
      - Generates AllowedActionSet (using existing AASBuilder)
      - Stores AAS in-memory for enforcement checks
      - Persists AAS to disk for audit

    NO autonomous behavior. NO background processes. NO scheduling.
    """

    MAX_CACHE_SIZE = 10_000  # Prevent memory exhaustion

    def __init__(
        self,
        decision_artifact_dir: str = "artifacts/civ/decisions",
        aas_artifact_dir: str = "artifacts/aas",
    ):
        """Initialize AAS provider.

        Args:
            decision_artifact_dir: Directory where Civ writes DecisionRecord artifacts
            aas_artifact_dir: Directory where AAS artifacts are persisted
        """
        self.decision_artifact_dir = decision_artifact_dir

        # Normalize and validate AAS artifact directory to prevent accidental
        # writes to absolute paths or escaping the repository root. Create the
        # directory if it does not exist.
        if os.path.isabs(aas_artifact_dir):
            raise ValueError("Absolute paths are not allowed for aas_artifact_dir")

        normalized = os.path.normpath(aas_artifact_dir)
        if normalized.startswith(".."):
            raise ValueError("aas_artifact_dir must not escape repository root")

        self.aas_artifact_dir = normalized
        os.makedirs(self.aas_artifact_dir, exist_ok=True)
        self._aas_cache: OrderedDict[UUID, AllowedActionSet] = OrderedDict()  # LRU cache
        self._cache_lock = threading.Lock()  # Thread-safe cache operations

    def generate_aas_from_decision(
        self,
        decision: DecisionRecord,
        validity_duration: timedelta = timedelta(hours=1),
    ) -> AllowedActionSet:
        """Generate AllowedActionSet from Civ DecisionRecord.

        This is the governance evaluation step: Civ produces DecisionRecord,
        governance consumes it and emits AllowedActionSet.

        Phase 6: Check AutonomyConstraint before allowing AAS generation.
        If autonomy is frozen, raise PermissionError.

        Phase 7: Sign AAS with Ed25519 before caching.

        Args:
            decision: DecisionRecord artifact from Civ
            validity_duration: How long AAS is valid (default: 1 hour, max: 24 hours)

        Returns:
            AllowedActionSet ready for enforcement checks (signed)

        Raises:
            PermissionError: If autonomy is frozen by operator
            ValueError: If validity_duration exceeds maximum
        """
        # Phase 6: Check AutonomyConstraint (operator-gated)
        constraint_manager = get_autonomy_constraint_manager()
        if not constraint_manager.is_governance_allowed():
            constraint = constraint_manager.get_current_constraint()
            raise PermissionError(f"Autonomy frozen by operator {constraint.set_by}: {constraint.reason}")

        # Enforce maximum validity duration
        MAX_AAS_VALIDITY = timedelta(hours=24)
        if validity_duration > MAX_AAS_VALIDITY:
            raise ValueError(f"AAS validity cannot exceed {MAX_AAS_VALIDITY}")

        # Log causality: Civ DecisionRecord → AAS generation
        log_aas_generation(
            decision_id=decision.decision_id,
            decision_type=decision.decision_type.value,
            provenance_hash=decision.provenance_hash,
        )

        # Use existing AASBuilder (no new abstractions)
        aas = AASBuilder.from_decision_record(
            decision=decision,
            validity_duration=validity_duration,
        )

        # Phase 8: Compute CCID (causal correlation ID) for observability
        # CCID binds all signals to sealed artifacts
        ccid = compute_ccid(
            decision_hash=decision.provenance_hash,
            aas_hash=aas.provenance_hash,
            scope=aas.scope,
            identity=aas.allowed_identities[0] if aas.allowed_identities else "unknown",
            issued_at=aas.generated_at,
        )
        object.__setattr__(aas, "ccid", ccid)

        # Phase 7: Sign AAS with Ed25519 before caching
        # Sign the canonical form (without signature field for determinism)
        signer = get_signer()
        import json

        aas_canonical = aas.canonical_form()
        aas_canonical_dict = json.loads(aas_canonical)
        signature = signer.sign(aas_canonical_dict)
        object.__setattr__(aas, "signature", signature)

        # Phase 8: Emit causal signals (log + metric) with CCID binding
        emit_causal_log(
            ccid=ccid,
            event_type="aas_generation",
            decision_hash=decision.provenance_hash,
            aas_hash=aas.provenance_hash,
            scope=aas.scope,
            identity=aas.allowed_identities[0] if aas.allowed_identities else "unknown",
            payload={
                "aas_id": str(aas.aas_id),
                "decision_id": str(aas.derived_from_decision_id),
                "allowed_actions": aas.allowed_actions,
                "valid_until": aas.valid_until.isoformat(),
            },
        )

        emit_causal_metric(
            ccid=ccid,
            metric_name="governance.aas.issued",
            metric_value=1.0,
            decision_hash=decision.provenance_hash,
            aas_hash=aas.provenance_hash,
            scope=aas.scope,
            identity=aas.allowed_identities[0] if aas.allowed_identities else "unknown",
            tags={"decision_type": decision.decision_type.value},
        )

        emit_causal_metric(
            ccid=ccid,
            metric_name="governance.decision.issued",
            metric_value=1.0,
            decision_hash=decision.provenance_hash,
            aas_hash=aas.provenance_hash,
            scope=aas.scope,
            identity=aas.allowed_identities[0] if aas.allowed_identities else "unknown",
            tags={"decision_type": decision.decision_type.value},
        )

        emit_causal_metric(
            ccid=ccid,
            metric_name="governance.aas.active",
            metric_value=1.0,
            decision_hash=decision.provenance_hash,
            aas_hash=aas.provenance_hash,
            scope=aas.scope,
            identity=aas.allowed_identities[0] if aas.allowed_identities else "unknown",
            tags={"result": "active", "reason": "ACTIVE"},
        )

        # Cache in-memory for enforcement checks (thread-safe with LRU eviction)
        with self._cache_lock:
            # Evict oldest if cache full
            if len(self._aas_cache) >= self.MAX_CACHE_SIZE:
                self._aas_cache.popitem(last=False)  # Remove oldest
            self._aas_cache[aas.aas_id] = aas

        # Persist to disk for audit
        AASWriter.write(aas, artifact_dir=self.aas_artifact_dir)

        return aas

    def load_decision_from_artifact(self, decision_id: UUID) -> Optional[DecisionRecord]:
        """Load DecisionRecord artifact from disk.

        Phase 7: Verify Ed25519 signature before returning.
        Reject artifacts with invalid or missing signatures.

        Args:
            decision_id: UUID of DecisionRecord to load

        Returns:
            DecisionRecord if found and signature valid, None otherwise

        Raises:
            ValueError: If signature is invalid or missing
        """
        artifact_path = Path(self.decision_artifact_dir) / f"{decision_id}.json"

        if not artifact_path.exists():
            return None

        with open(artifact_path, "r") as f:
            data = json.load(f)

        # Phase 7: Verify signature before reconstructing
        signature = data.get("signature", "")
        if not signature:
            raise ValueError(f"DecisionRecord {decision_id} missing signature (Phase 7 requirement)")

        # Reconstruct DecisionRecord from JSON
        record = DecisionRecord.from_dict(data)

        # Verify signature
        signer = get_signer()
        if not signer.verify(record.to_dict(), signature):
            raise ValueError(f"DecisionRecord {decision_id} signature verification failed")

        return record

    def get_aas(self, aas_id: UUID) -> Optional[AllowedActionSet]:
        """Retrieve cached AllowedActionSet.

        Args:
            aas_id: UUID of AAS to retrieve

        Returns:
            AllowedActionSet if found, None otherwise
        """
        return self._aas_cache.get(aas_id)

    def get_active_aas_for_action(self, action: str, identity: str) -> Optional[AllowedActionSet]:
        """Find active AAS that permits action for identity.

        Args:
            action: Action to check (e.g., "vector.write")
            identity: SPIFFE ID to check

        Returns:
            First valid AAS that permits action and identity, None if none found
        """
        current_time = datetime.now()

        for aas in self._aas_cache.values():
            if not aas.is_valid(current_time):
                continue

            if aas.allows_action(action) and aas.allows_identity(identity):
                return aas

        return None

    def get_active_aas_for_identity(self, identity: str) -> Optional[AllowedActionSet]:
        """Find the most recent active AAS for an identity (action-agnostic).

        Args:
            identity: SPIFFE ID to check

        Returns:
            Most recent active AAS for identity, None if none found
        """
        current_time = datetime.now()
        candidates: list[AllowedActionSet] = []

        for aas in self._aas_cache.values():
            if not aas.is_valid(current_time):
                continue
            if aas.allows_identity(identity):
                candidates.append(aas)

        if not candidates:
            return None

        return max(candidates, key=lambda item: item.generated_at)

    def clear_expired(self) -> int:
        """Remove expired AAS from cache.

        Returns:
            Number of expired AAS removed
        """
        current_time = datetime.now()
        expired_ids = [aas_id for aas_id, aas in self._aas_cache.items() if not aas.is_valid(current_time)]

        for aas_id in expired_ids:
            aas = self._aas_cache[aas_id]

            decision_hash = f"DERIVED_FROM_AAS:{aas.derived_from_decision_id}"
            decision = self.load_decision_from_artifact(aas.derived_from_decision_id)
            if decision is not None:
                decision_hash = decision.provenance_hash

            emit_causal_metric(
                ccid=aas.ccid or "MISSING_CCID",
                metric_name="governance.aas.active",
                metric_value=0.0,
                decision_hash=decision_hash,
                aas_hash=aas.provenance_hash,
                scope=aas.scope,
                identity=aas.allowed_identities[0] if aas.allowed_identities else "unknown",
                tags={"result": "expired", "reason": "EXPIRED"},
            )

            del self._aas_cache[aas_id]

        return len(expired_ids)

    def load_aas_from_artifacts(self) -> int:
        """Load AAS artifacts from disk into cache.

        Called on startup to restore active AAS from persisted artifacts.
        Only loads AAS that are still valid (not expired).

        Returns:
            Number of AAS loaded into cache
        """
        from runtime.governance.allowed_action_set import AllowedActionSet

        artifact_dir = Path(self.aas_artifact_dir)
        if not artifact_dir.exists():
            return 0

        loaded_count = 0
        current_time = datetime.now()

        for artifact_path in artifact_dir.glob("*.json"):
            try:
                with open(artifact_path, "r") as f:
                    data = json.load(f)

                aas = AllowedActionSet.from_dict(data)

                # Only load if still valid
                if not aas.is_valid(current_time):
                    continue

                # Cache for enforcement
                with self._cache_lock:
                    if len(self._aas_cache) >= self.MAX_CACHE_SIZE:
                        self._aas_cache.popitem(last=False)
                    self._aas_cache[aas.aas_id] = aas

                loaded_count += 1

            except Exception as e:
                # Log but don't fail on individual artifact errors
                import logging

                logging.getLogger("runtime").warning(f"Failed to load AAS artifact {artifact_path}: {e}")

        return loaded_count


def enforce_with_aas(
    aas_provider: AASProvider,
    action: str,
    identity: str,
    log_path: str = "artifacts/logs/governance_aas.jsonl",
) -> None:
    """Enforce action against AllowedActionSet.

    Phase 2: Autonomous containment on denial.
    Phase 7: Replay protection check before enforcement.

    This is the enforcement choke point: actions MUST be in an active AAS
    to be permitted, and must not be a replay of a previous enforcement.

    Args:
        aas_provider: AAS provider with cached AAS
        action: Action to check (e.g., "vector.write")
        identity: SPIFFE ID attempting action
        log_path: Path to causality log

    Raises:
        PermissionError: If action is denied or replayed
    """
    # Find active AAS that permits action for identity
    aas = aas_provider.get_active_aas_for_action(action, identity)

    if aas is None:
        # DENY: No AAS permits action
        enforcement_outcome = "deny"
        decision_provenance_hash = "NO_AAS"

        context_aas = aas_provider.get_active_aas_for_identity(identity)
        if context_aas is not None:
            context_decision = aas_provider.load_decision_from_artifact(context_aas.derived_from_decision_id)
            if context_decision is not None:
                decision_provenance_hash = context_decision.provenance_hash
            else:
                decision_provenance_hash = f"DERIVED_FROM_AAS:{context_aas.derived_from_decision_id}"

            emit_causal_log(
                ccid=context_aas.ccid or "MISSING_CCID",
                event_type="enforcement",
                decision_hash=decision_provenance_hash,
                aas_hash=context_aas.provenance_hash,
                scope=context_aas.scope,
                identity=identity,
                payload={
                    "action": action,
                    "outcome": enforcement_outcome,
                    "reason": "NO_ACTIVE_AAS",
                    "aas_id": str(context_aas.aas_id),
                },
            )

            emit_causal_metric(
                ccid=context_aas.ccid or "MISSING_CCID",
                metric_name="governance.enforcement.denied",
                metric_value=1.0,
                decision_hash=decision_provenance_hash,
                aas_hash=context_aas.provenance_hash,
                scope=context_aas.scope,
                identity=identity,
                tags={"action": action, "result": "deny", "reason": "NO_ACTIVE_AAS"},
            )

        log_entry = {
            "event": "governance.aas_enforcement",
            "aas_id": None,
            "decision_id": None,
            "decision_provenance_hash": decision_provenance_hash,
            "aas_provenance_hash": None,
            "action": action,
            "identity": identity,
            "outcome": enforcement_outcome,
            "reason": "NO_ACTIVE_AAS",
            "timestamp": datetime.now().isoformat(),
            "causality_chain": {
                "signal": "observability_metrics",
                "civ_decision": None,
                "aas": None,
                "enforcement": enforcement_outcome,
            },
        }

        # Log causality
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a") as f:
            f.write(json.dumps(log_entry) + "\n")

        # Phase 2: Autonomous containment on denial
        from runtime.governance.containment import ContainmentReason, get_containment_engine

        containment = get_containment_engine()
        containment.deny_execution(
            identity_spiffe_id=identity,
            resource=action,
            reason=ContainmentReason.NO_ACTIVE_AAS,
            causality_chain=log_entry["causality_chain"],
        )

        raise PermissionError(f"Action '{action}' denied for identity '{identity}': No active AAS permits action")

    # Phase 7: Check replay protection before proceeding
    replay_protection = get_replay_protection()
    is_replay, replay_error = replay_protection.check_and_record(
        decision_id=str(aas.derived_from_decision_id),
        action=action,
        identity=identity,
    )

    if is_replay:
        # DENY: Replay attack detected
        enforcement_outcome = "deny"
        decision_provenance_hash = "NO_AAS"

        decision = aas_provider.load_decision_from_artifact(aas.derived_from_decision_id)
        if decision is not None:
            decision_provenance_hash = decision.provenance_hash
        else:
            decision_provenance_hash = f"DERIVED_FROM_AAS:{aas.derived_from_decision_id}"

        log_entry = {
            "event": "governance.aas_enforcement",
            "aas_id": str(aas.aas_id),
            "decision_id": str(aas.derived_from_decision_id),
            "decision_provenance_hash": decision_provenance_hash,
            "aas_provenance_hash": aas.provenance_hash,
            "action": action,
            "identity": identity,
            "outcome": enforcement_outcome,
            "reason": "REPLAY_ATTACK_DETECTED",
            "replay_error": replay_error,
            "timestamp": datetime.now().isoformat(),
            "causality_chain": {
                "signal": "observability_metrics",
                "civ_decision": None,
                "aas": aas.provenance_hash,
                "enforcement": enforcement_outcome,
            },
        }

        # Log causality
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a") as f:
            f.write(json.dumps(log_entry) + "\n")

        emit_causal_log(
            ccid=aas.ccid or "MISSING_CCID",
            event_type="enforcement",
            decision_hash=decision_provenance_hash,
            aas_hash=aas.provenance_hash,
            scope=aas.scope,
            identity=identity,
            payload={
                "action": action,
                "outcome": enforcement_outcome,
                "reason": "REPLAY_ATTACK_DETECTED",
                "aas_id": str(aas.aas_id),
            },
        )

        emit_causal_metric(
            ccid=aas.ccid or "MISSING_CCID",
            metric_name="governance.enforcement.denied",
            metric_value=1.0,
            decision_hash=decision_provenance_hash,
            aas_hash=aas.provenance_hash,
            scope=aas.scope,
            identity=identity,
            tags={"action": action, "result": "deny", "reason": "REPLAY_ATTACK_DETECTED"},
        )

        # Phase 2: Autonomous containment on denial
        from runtime.governance.containment import ContainmentReason, get_containment_engine

        containment = get_containment_engine()
        containment.deny_execution(
            identity_spiffe_id=identity,
            resource=action,
            reason=ContainmentReason.NO_ACTIVE_AAS,
            causality_chain=log_entry["causality_chain"],
        )

        raise PermissionError(f"Action '{action}' denied for identity '{identity}': Replay attack detected")

    # ALLOW: AAS permits action and not a replay
    enforcement_outcome = "allow"

    # Fetch real provenance hash from DecisionRecord (if available)
    decision = aas_provider.load_decision_from_artifact(aas.derived_from_decision_id)
    if decision is not None:
        decision_provenance_hash = decision.provenance_hash
    else:
        # DecisionRecord artifact not found - use AAS-derived fallback
        # This can happen if DecisionRecord was generated but not persisted,
        # or if artifact was pruned for space. Not a security issue since
        # AAS itself is already validated.
        decision_provenance_hash = f"DERIVED_FROM_AAS:{aas.derived_from_decision_id}"

    # Phase 8: Use AAS CCID (already computed during generation)
    ccid = aas.ccid if aas.ccid else "MISSING_CCID"

    # Phase 8: Emit causal enforcement signal with CCID binding
    emit_causal_log(
        ccid=ccid,
        event_type="enforcement",
        decision_hash=decision_provenance_hash,
        aas_hash=aas.provenance_hash,
        scope=aas.scope,
        identity=identity,
        payload={
            "action": action,
            "outcome": enforcement_outcome,
            "aas_id": str(aas.aas_id),
        },
    )

    emit_causal_metric(
        ccid=ccid,
        metric_name="governance.enforcement.allowed",
        metric_value=1.0,
        decision_hash=decision_provenance_hash,
        aas_hash=aas.provenance_hash,
        scope=aas.scope,
        identity=identity,
        tags={"action": action, "result": "allow", "reason": "ALLOWED"},
    )

    log_entry = log_aas_causality(
        aas=aas,
        decision_provenance_hash=decision_provenance_hash,
        enforcement_outcome=enforcement_outcome,
        action=action,
        identity=identity,
    )

    # Log causality
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a") as f:
        f.write(json.dumps(log_entry) + "\n")

    # Success: action permitted
