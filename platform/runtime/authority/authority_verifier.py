# =============================================================================
# ThreadForge — Authority Verifier
# Phase 11: Authority Replay & Cryptographic Verification (READ-ONLY)
# runtime/authority/authority_verifier.py
# =============================================================================

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone

from runtime.authority.replay_context import ReplayAuthorityContext
from runtime.authority.verification_result import VerificationResult
from runtime.identity.capabilities import CapabilitySet
from runtime.identity.context import IdentityContext
from runtime.ledger.seal import AuthoritySeal


def recompute_seal_hash(
    identity: IdentityContext,
    capabilities: CapabilitySet,
    delegation_ids: tuple[str, ...],
    policy_hash: str,
    plan_digest: str,
    timestamp: datetime,
) -> str:
    """Recompute the expected authority seal hash deterministically.

    Phase 11: Pure function that recomputes what the seal should be.
    No runtime state queries, no governance calls.
    """
    # Create canonical dictionary representation matching AuthoritySeal.as_dict()
    seal_dict = {
        "spiffe_id": identity.spiffe_id,
        "trust_domain": identity.trust_domain,
        "effective_capabilities": sorted(capabilities.capabilities),
        "active_delegation_ids": sorted(delegation_ids),
        "governing_policy_hash": policy_hash,
        "decision_outcome": "ALLOW",  # Always ALLOW for verification (decisions are sealed post-enforcement)
        "timestamp": timestamp.isoformat(),
        "plan_hash": plan_digest,
    }

    # Canonical JSON serialization
    canonical_json = json.dumps(seal_dict, sort_keys=True, separators=(",", ":"))

    # SHA3-512 hash
    hash_obj = hashlib.sha3_512()
    hash_obj.update(canonical_json.encode("utf-8"))
    return f"sha3-512:{hash_obj.hexdigest()}"


def verify_seal(
    seal: AuthoritySeal,
    replay_context: ReplayAuthorityContext,
    plan_digest: str,
) -> VerificationResult:
    """Cryptographically verify an AuthoritySeal against replay context.

    Phase 11: Deterministic verification with no side effects.
    Compares stored seal against recomputed expectation.
    """
    verified_at = datetime.now(timezone.utc)
    mismatches = []

    # Recompute expected hash
    expected_hash = recompute_seal_hash(
        identity=replay_context.identity,
        capabilities=replay_context.capabilities,
        delegation_ids=replay_context.delegation_ids,
        policy_hash=replay_context.policy_hash,
        plan_digest=plan_digest,
        timestamp=replay_context.timestamp,
    )

    # Compare stored vs expected
    stored_hash = seal.compute_hash()
    if stored_hash != expected_hash:
        mismatches.append(f"Hash mismatch: stored={stored_hash}, expected={expected_hash}")

    # Verify structural consistency
    if seal.spiffe_id != replay_context.identity.spiffe_id:
        mismatches.append(f"SPIFFE ID mismatch: seal={seal.spiffe_id}, context={replay_context.identity.spiffe_id}")

    if seal.trust_domain != replay_context.identity.trust_domain:
        mismatches.append(
            f"Trust domain mismatch: seal={seal.trust_domain}, " f"context={replay_context.identity.trust_domain}"
        )

    if seal.effective_capabilities != replay_context.capabilities.capabilities:
        mismatches.append(
            f"Capabilities mismatch: seal={sorted(seal.effective_capabilities)}, "
            f"context={sorted(replay_context.capabilities.capabilities)}"
        )

    if seal.active_delegation_ids != set(replay_context.delegation_ids):
        mismatches.append(
            f"Delegation IDs mismatch: seal={sorted(seal.active_delegation_ids)}, "
            f"context={sorted(replay_context.delegation_ids)}"
        )

    if seal.governing_policy_hash != replay_context.policy_hash:
        mismatches.append(
            f"Policy hash mismatch: seal={seal.governing_policy_hash}, " f"context={replay_context.policy_hash}"
        )

    if seal.plan_hash != plan_digest:
        mismatches.append(f"Plan hash mismatch: seal={seal.plan_hash}, expected={plan_digest}")

    # Decision outcome should always be ALLOW (sealing happens post-enforcement)
    if seal.decision_outcome != "ALLOW":
        mismatches.append(f"Decision outcome invalid: {seal.decision_outcome} (expected ALLOW)")

    # Verify timestamp consistency (within reasonable tolerance)
    time_diff = abs((seal.timestamp - replay_context.timestamp).total_seconds())
    if time_diff > 60:  # 1 minute tolerance
        mismatches.append(f"Timestamp mismatch: seal={seal.timestamp}, context={replay_context.timestamp}")

    verified = len(mismatches) == 0
    reason = (
        "Authority seal verified successfully"
        if verified
        else f"Authority seal verification failed: {len(mismatches)} mismatches"
    )

    return VerificationResult(
        verified=verified,
        reason=reason,
        mismatches=tuple(mismatches),
        verified_at=verified_at,
    )
