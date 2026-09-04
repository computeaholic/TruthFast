"""
Civ Engine Provenance Layer — Decision Attribution & Traceability.

Phase D: Decision Provenance Core
Phase H: Audit System Hardening (Cryptographic Signing Added)

This layer transforms Civ outputs from raw metrics into cryptographically
attributable decision objects that explain WHY pressure exists, not just
that it exists.

Core Components:

1. decision_record.py
   - DecisionRecord dataclass (canonical structure)
   - DecisionType enum (budget, policy, denial, composite)
   - Supporting data structures (TimeWindow, Inputs, Metrics, Contributors, Recommendation)
   - Deterministic provenance_hash computation

2. decision_builder.py
   - ProvenanceBuilder (assembles DecisionRecords from Civ outputs)
   - Methods: build_budget_pressure_decision, build_policy_pressure_decision, build_composite_decision
   - Normalizes contributors, computes derived metrics, generates recommendations

3. artifact_writer.py
   - ArtifactWriter (persists DecisionRecords to disk)
   - Formats: JSON (machine-readable), Markdown (human-readable)
   - Artifacts stored to artifacts/civ/decisions/
   - Phase H: All JSON artifacts cryptographically signed (Ed25519)

4. artifact_signing.py (Phase H)
   - ArtifactSigner (Ed25519 signing for decision artifacts)
   - SignatureVerifier (Ed25519 signature verification)
   - SigningError (fail-closed error handling)
   - Deterministic signatures, offline verification

Global Invariants:

1. Civ SHALL NOT:
   - Write to authority tables
   - Flip enforcement flags
   - Schedule execution
   - Invoke require() or capability checks
   - Emit executable signals

2. Civ SHALL:
   - Be deterministic and replayable
   - Produce machine-consumable artifacts (JSON)
   - Produce human-readable explanations (Markdown)
   - Clearly label outputs as NON-BINDING
   - Sign all canonical artifacts (Phase H)

3. All enforcement remains external

Public API:

    from runtime.civ.provenance import (
        DecisionRecord,
        ProvenanceBuilder,
        ArtifactWriter,
        ArtifactSigner,         # Phase H
        SignatureVerifier,      # Phase H
        SigningError,           # Phase H
    )

    builder = ProvenanceBuilder(query_execution_context={...})
    decision = builder.build_budget_pressure_decision(...)
    writer = ArtifactWriter()  # Signing is automatic
    writer.write_decision(decision)
"""

from runtime.civ.provenance.artifact_signing import ArtifactSigner, SignatureVerifier, SigningError
from runtime.civ.provenance.artifact_writer import ArtifactWriter
from runtime.civ.provenance.decision_builder import ProvenanceBuilder
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

__all__ = [
    "DecisionRecord",
    "DecisionType",
    "TimeWindow",
    "InputSpecification",
    "DerivedMetrics",
    "Contributor",
    "ContributorType",
    "CounterfactualSensitivity",
    "Recommendation",
    "ProvenanceBuilder",
    "ArtifactWriter",
    "ArtifactSigner",
    "SignatureVerifier",
    "SigningError",
]
