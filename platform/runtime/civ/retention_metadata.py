"""
Phase H: Retention Metadata Standardization

Defines canonical retention metadata schema for all audit and decision artifacts.

This module provides:
1. RetentionMetadata dataclass - canonical schema
2. RetentionClass enum - classification of artifact retention intent
3. Emission functions - mechanical metadata generation

Scope:
- Metadata emission only (no deletion/purging logic)
- Applied to: Civ decisions, doctor gates, delegation audits
- Fail-closed: missing metadata = error

Global Invariants:
- All canonical artifacts MUST emit retention metadata
- Metadata is descriptive, not prescriptive (no automated purging)
- Retention intent is documented mechanically, not just textually
"""

import json
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Literal, Optional


class RetentionClass(str, Enum):
    """
    Classification of artifact retention intent.

    CANONICAL: Long-term preservation (audit trail, decisions)
    EPHEMERAL: Short-term working artifacts (gates, probes)
    WORKING: Intermediate artifacts (raw data, analysis)
    """

    CANONICAL = "canonical"
    EPHEMERAL = "ephemeral"
    WORKING = "working"


ArtifactType = Literal[
    "decision",
    "audit",
    "gate_evidence",
    "delegation_audit",
    "provenance",
]


@dataclass(frozen=True)
class RetentionMetadata:
    """
    Canonical retention metadata for audit and decision artifacts.

    Fields:
        artifact_type: Type of artifact (decision, audit, gate_evidence, etc.)
        artifact_id: Unique identifier for the artifact
        created_at: ISO8601 timestamp of artifact creation (UTC)
        retention_class: Classification (canonical, ephemeral, working)
        retention_days: Intended retention period in days
        authority_level: Authority level (non_binding, evidence_only, procedural)
        source_system: System that produced the artifact
        description: Human-readable description of retention intent

    Retention Guidelines (Descriptive, Not Automated):
    - CANONICAL artifacts: 2555 days (7 years) - audit trail preservation
    - EPHEMERAL artifacts: 90 days - gate evidence, probes
    - WORKING artifacts: 365 days - intermediate analysis artifacts
    """

    artifact_type: ArtifactType
    artifact_id: str
    created_at: str
    retention_class: RetentionClass
    retention_days: int
    authority_level: Literal["non_binding", "evidence_only", "procedural"]
    source_system: str
    description: str

    def to_json(self) -> str:
        """Serialize to JSON string."""
        return json.dumps(asdict(self), indent=2)

    def to_dict(self) -> dict:
        """Convert to dictionary."""
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "RetentionMetadata":
        """Create from dictionary."""
        # Convert retention_class string to enum if needed
        if isinstance(data.get("retention_class"), str):
            data["retention_class"] = RetentionClass(data["retention_class"])
        return cls(**data)


def create_decision_retention_metadata(
    decision_id: str,
    created_at: Optional[str] = None,
) -> RetentionMetadata:
    """
    Create retention metadata for a Civ decision artifact.

    Args:
        decision_id: Unique decision ID (provenance_hash)
        created_at: ISO8601 timestamp (defaults to now)

    Returns:
        RetentionMetadata with CANONICAL retention class
    """
    if created_at is None:
        created_at = datetime.now(timezone.utc).isoformat()

    return RetentionMetadata(
        artifact_type="decision",
        artifact_id=decision_id,
        created_at=created_at,
        retention_class=RetentionClass.CANONICAL,
        retention_days=2555,  # 7 years
        authority_level="non_binding",
        source_system="civ_engine",
        description="Civ decision artifact with cryptographic provenance",
    )


def create_gate_evidence_retention_metadata(
    gate_id: str,
    drill_id: str,
    created_at: Optional[str] = None,
) -> RetentionMetadata:
    """
    Create retention metadata for doctor gate evidence.

    Args:
        gate_id: Gate identifier (e.g., "collector", "spire")
        drill_id: Drill ID for this gate execution
        created_at: ISO8601 timestamp (defaults to now)

    Returns:
        RetentionMetadata with EPHEMERAL retention class
    """
    if created_at is None:
        created_at = datetime.now(timezone.utc).isoformat()

    artifact_id = f"{gate_id}-{drill_id}"

    return RetentionMetadata(
        artifact_type="gate_evidence",
        artifact_id=artifact_id,
        created_at=created_at,
        retention_class=RetentionClass.EPHEMERAL,
        retention_days=90,
        authority_level="evidence_only",
        source_system="doctor_gate",
        description=f"Doctor gate evidence for {gate_id}",
    )


def create_delegation_audit_retention_metadata(
    audit_id: str,
    created_at: Optional[str] = None,
) -> RetentionMetadata:
    """
    Create retention metadata for delegation audit artifacts.

    Args:
        audit_id: Unique audit identifier
        created_at: ISO8601 timestamp (defaults to now)

    Returns:
        RetentionMetadata with CANONICAL retention class
    """
    if created_at is None:
        created_at = datetime.now(timezone.utc).isoformat()

    return RetentionMetadata(
        artifact_type="delegation_audit",
        artifact_id=audit_id,
        created_at=created_at,
        retention_class=RetentionClass.CANONICAL,
        retention_days=2555,  # 7 years
        authority_level="procedural",
        source_system="delegation_audit",
        description="Delegation audit artifact",
    )


def write_retention_metadata(
    metadata: RetentionMetadata,
    artifact_path: Path,
) -> Path:
    """
    Write retention metadata to disk alongside artifact.

    Creates a .retention.json file with the same base name as the artifact.

    Args:
        metadata: RetentionMetadata instance
        artifact_path: Path to the artifact file

    Returns:
        Path to the created retention metadata file

    Raises:
        OSError: If unable to write metadata file
    """
    retention_path = artifact_path.parent / f"{artifact_path.name}.retention.json"
    retention_path.write_text(metadata.to_json())
    return retention_path


def read_retention_metadata(retention_path: Path) -> RetentionMetadata:
    """
    Read retention metadata from disk.

    Args:
        retention_path: Path to .retention.json file

    Returns:
        RetentionMetadata instance

    Raises:
        OSError: If unable to read file
        json.JSONDecodeError: If file is not valid JSON
        ValueError: If metadata is invalid
    """
    data = json.loads(retention_path.read_text())
    return RetentionMetadata.from_dict(data)
