"""Evidence Schema Validation (Phase 2B Item 7)

Enforces mechanical validation of evidence classification markers to prevent
semantic drift and future misuse of synthetic/simulated evidence.

Principle: Anything that can plausibly be mistaken for enforcement evidence
must be mechanically guarded — even if not consumed today.

Required fields:
- evidence_kind ∈ {real, simulated, demo}
- synthetic (boolean)

Invariant: No evidence object may enter any ledger or persistence layer
without unambiguous classification.
"""

from typing import Any, Literal

EvidenceKind = Literal["real", "simulated", "demo"]


class EvidenceValidationError(ValueError):
    """Raised when evidence fails schema validation at ingestion boundary."""

    pass


def validate_evidence_classification(evidence: dict[str, Any]) -> None:
    """Validate evidence contains required classification markers.

    Args:
        evidence: Evidence dict to validate

    Raises:
        EvidenceValidationError: If evidence lacks required markers or has
            inconsistent classification

    Required fields:
    - evidence_kind ∈ {real, simulated, demo}
    - synthetic (boolean)

    Consistency rules:
    - synthetic=true REQUIRES evidence_kind ∈ {simulated, demo}
    - evidence_kind=real REQUIRES synthetic=false
    """
    # Require evidence_kind field
    if "evidence_kind" not in evidence:
        raise EvidenceValidationError(
            "Evidence missing required field: evidence_kind. " "Must be one of: real, simulated, demo"
        )

    evidence_kind = evidence["evidence_kind"]

    # Enforce evidence_kind enumeration
    valid_kinds = {"real", "simulated", "demo"}
    if evidence_kind not in valid_kinds:
        raise EvidenceValidationError(f"Invalid evidence_kind: {evidence_kind!r}. Must be one of: {valid_kinds}")

    # Require synthetic field
    if "synthetic" not in evidence:
        raise EvidenceValidationError("Evidence missing required field: synthetic (boolean)")

    synthetic = evidence["synthetic"]

    # Enforce boolean type
    if not isinstance(synthetic, bool):
        raise EvidenceValidationError(f"Field 'synthetic' must be boolean, got {type(synthetic).__name__}")

    # Enforce consistency: synthetic=true requires simulated/demo kind
    if synthetic and evidence_kind not in {"simulated", "demo"}:
        raise EvidenceValidationError(
            f"Inconsistent classification: synthetic=true but evidence_kind={evidence_kind!r}. "
            "synthetic=true REQUIRES evidence_kind ∈ {{simulated, demo}}"
        )

    # Enforce consistency: real evidence cannot be synthetic
    if evidence_kind == "real" and synthetic:
        raise EvidenceValidationError(
            "Inconsistent classification: evidence_kind=real but synthetic=true. "
            "Real evidence must have synthetic=false"
        )
