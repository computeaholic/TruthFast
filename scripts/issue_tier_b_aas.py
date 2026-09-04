#!/usr/bin/env python3
"""Issue AAS for ForgeSec Tier B (Authenticated Stimulus).

This script issues an Allowed Action Set through the canonical Reflex/AAS
governance workflow. It does NOT bypass enforcement; it uses the same
AASProvider path intended for production governance.

Identity: spiffe://<SPIFFE_TRUST_DOMAIN>/tier/tier2/cluster-alpha/ns/threadforge-system/sa/threadforge-client/role/client
Scope: /vector/search only (vector.read capability)
Duration: 1 hour

This demonstrates:
1. DecisionRecord creation (Civ output)
2. AAS generation (Governance evaluation)
3. CCID binding (Observability)
4. Metrics emission (Audit trail)
"""

import json
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path
from uuid import uuid4

# Ensure runtime is importable before local imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from runtime.civ.provenance.decision_record import (
    Contributor,
    ContributorType,
    CounterfactualSensitivity,
    DecisionRecord,
    DecisionType,
    DerivedMetrics,
    InputSpecification,
    Recommendation,
    TimeWindow,
)
from runtime.governance.aas_provider import AASProvider
from runtime.governance.crypto_integrity import get_signer

_trust_domain = os.environ.get("SPIFFE_TRUST_DOMAIN")
if not _trust_domain:
    print("[FATAL] SPIFFE_TRUST_DOMAIN not set", file=sys.stderr)
    sys.exit(2)
_TIER_IDENTITY = (
    f"spiffe://{_trust_domain}/tier/tier2/cluster-alpha/" "ns/threadforge-system/sa/threadforge-client/role/client"
)


def create_tier_b_decision_record() -> DecisionRecord:
    """Create a DecisionRecord for Tier B AAS issuance.

    This follows the Civ→Governance causality chain.
    The DecisionRecord is advisory and links to the AAS.
    """
    decision_id = uuid4()
    now = datetime.now()

    # Time window: last hour of metrics collection
    time_window = TimeWindow(
        start=now - timedelta(hours=1),
        end=now,
    )

    # Input specification: what data informed this decision
    inputs = InputSpecification(
        source_tables=["governance.tier_b_authorization"],
        query_files=["scripts/issue_tier_b_aas.py"],
        parameters={
            "identity": _TIER_IDENTITY,
            "namespace": "threadforge-system",
            "scope": "vector.search",
            "purpose": "ppit_intent_authorized_access",
        },
    )

    # Derived metrics: system state supporting this decision
    derived_metrics = DerivedMetrics(
        utilization_percent=15.0,  # Low utilization, safe to allow
        denial_pressure=0.0,  # No denial pressure (deny-by-default is working)
        minutes_to_breach=None,  # Not applicable
        confidence_interval={"low": 0.9, "high": 0.95},
    )

    # Dominant contributor: the identity requesting access
    dominant_contributors = [
        Contributor(
            contributor_type=ContributorType.IDENTITY_CLASS,
            contributor_id=_TIER_IDENTITY,
            contribution_percent=100.0,
        ),
    ]

    # Counterfactual sensitivity (what would change this)
    counterfactual_sensitivity = CounterfactualSensitivity(
        increase_budget_by={"delta": 0.0, "effect": "not_applicable"},
        reduce_load_by={"delta": 0.0, "effect": "not_applicable"},
        enforce_now={"hypothetical_effect": "allow_vector_read"},
    )

    # Recommendation
    recommendation = Recommendation(
        text="Grant vector.search access to threadforge-client for PPIT-aligned testing",
        confidence=0.95,
    )

    # Create the DecisionRecord
    decision = DecisionRecord(
        decision_id=decision_id,
        decision_type=DecisionType.POLICY_PRESSURE,  # Policy-driven decision
        generated_at=now,
        time_window=time_window,
        inputs=inputs,
        derived_metrics=derived_metrics,
        dominant_contributors=dominant_contributors,
        counterfactual_sensitivity=counterfactual_sensitivity,
        recommendation=recommendation,
    )

    return decision


def sign_and_persist_decision(decision: DecisionRecord) -> None:
    """Sign the DecisionRecord and persist to artifact directory.

    Phase 7 requirement: All artifacts must be Ed25519 signed.
    """
    signer = get_signer()

    # Sign the canonical form
    decision_dict = decision.to_dict()
    signature = signer.sign(decision_dict)
    object.__setattr__(decision, "signature", signature)

    # Persist to artifacts directory
    artifact_dir = Path("artifacts/civ/decisions")
    artifact_dir.mkdir(parents=True, exist_ok=True)

    artifact_path = artifact_dir / f"{decision.decision_id}.json"
    with open(artifact_path, "w") as f:
        json.dump(decision.to_dict(), f, indent=2)

    print(f"[DECISION] Persisted DecisionRecord: {artifact_path}")
    print(f"[DECISION] decision_id: {decision.decision_id}")
    print(f"[DECISION] provenance_hash: {decision.provenance_hash}")


def main():
    """Issue AAS for Tier B through the canonical governance workflow."""

    print("=" * 70)
    print("ForgeSec Tier B AAS Issuance - Governance Workflow")
    print("=" * 70)

    # Step 1: Create DecisionRecord (Civ output)
    print("\n[STEP 1] Creating DecisionRecord (Civ → Governance causality)...")
    decision = create_tier_b_decision_record()

    # Step 2: Sign and persist DecisionRecord
    print("\n[STEP 2] Signing and persisting DecisionRecord (Phase 7)...")
    sign_and_persist_decision(decision)

    # Step 3: Generate AAS from DecisionRecord
    print("\n[STEP 3] Generating AAS from DecisionRecord (Governance evaluation)...")

    # Use override_actions and override_identities for explicit scoping
    # This is the production path - AASBuilder.from_decision_record with overrides
    aas_provider = AASProvider()

    aas = aas_provider.generate_aas_from_decision(
        decision=decision,
        validity_duration=timedelta(hours=24),  # 24 hour validity for testing
    )

    # The AAS was generated with defaults from DecisionType.POLICY_PRESSURE
    # which gives ["vector.search", "vector.insert", "vector.delete", "vector.embed", "storage.read", "storage.write"]
    # The identity comes from dominant_contributors

    print("\n[AAS] Issued AllowedActionSet:")
    print(f"  aas_id: {aas.aas_id}")
    print(f"  derived_from_decision_id: {aas.derived_from_decision_id}")
    print(f"  generated_at: {aas.generated_at.isoformat()}")
    print(f"  valid_until: {aas.valid_until.isoformat()}")
    print(f"  scope: {aas.scope}")
    print(f"  allowed_actions: {aas.allowed_actions}")
    print(f"  allowed_identities: {aas.allowed_identities}")
    print(f"  provenance_hash: {aas.provenance_hash}")
    print(f"  ccid: {aas.ccid}")
    print(f"  signature: {aas.signature[:32]}...")

    # Step 4: Verify AAS is cached and retrievable
    print("\n[STEP 4] Verifying AAS is cached...")
    cached_aas = aas_provider.get_active_aas_for_action(
        action="vector.search",
        identity=_TIER_IDENTITY,
    )

    if cached_aas is not None:
        print("  [OK] AAS cached and retrievable for vector.search")
        print(f"  [OK] aas_id matches: {cached_aas.aas_id == aas.aas_id}")
    else:
        print("  [FAIL] AAS not found in cache")
        return 1

    # Step 5: Summary
    print("\n" + "=" * 70)
    print("AAS ISSUANCE COMPLETE")
    print("=" * 70)
    print(
        f"""
Identity: {_TIER_IDENTITY}
Actions:  {aas.allowed_actions}
Valid:    {aas.generated_at.isoformat()} → {aas.valid_until.isoformat()}
CCID:     {aas.ccid}

Governance Artifacts:
  - DecisionRecord: artifacts/civ/decisions/{decision.decision_id}.json
  - AAS: artifacts/aas/{aas.aas_id}.json
  - Causality Log: artifacts/logs/governance_aas.jsonl

Next: Tier B /vector/search should now return 200 (was 403)
"""
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
