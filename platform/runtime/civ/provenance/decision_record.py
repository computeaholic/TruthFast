"""
Decision Provenance Core — DecisionRecord and Provenance Data Structures.

Phase D: Decision Provenance Core

This module defines the canonical DecisionRecord structure, which transforms
Civ outputs from raw metrics into cryptographically attributable decision
objects that explain WHY pressure exists, not just that it exists.

Global Invariant: This module SHALL NOT write to authority tables, flip
enforcement flags, schedule execution, or emit executable signals. All outputs
are strictly advisory and non-binding.

Canonical Structure:

DecisionRecord:
  - decision_id: UUID (unique identifier)
  - decision_type: enum (budget_pressure, policy_pressure, denial_pressure, composite)
  - generated_at: timestamp (decision creation time)
  - time_window: {start, end} (metric collection window)
  - inputs: {source_tables, query_files, parameters}
  - derived_metrics: {utilization_percent, denial_pressure, minutes_to_breach, confidence_interval}
  - dominant_contributors: [{contributor_type, contributor_id, contribution_percent}]
  - counterfactual_sensitivity: {increase_budget_by, reduce_load_by, enforce_now}
  - recommendation: {text, confidence}
  - classification: "ADVISORY_ONLY" (fixed)
  - enforcement_prohibited: true (fixed)
  - provenance_hash: sha256 (deterministic over inputs + derived + contributors)
"""

import hashlib
import json
import re
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional
from uuid import UUID


class DecisionType(str, Enum):
    """Enumeration of decision types produced by Civ Engine."""

    BUDGET_PRESSURE = "budget_pressure"
    POLICY_PRESSURE = "policy_pressure"
    DENIAL_PRESSURE = "denial_pressure"
    COMPOSITE = "composite"


class ContributorType(str, Enum):
    """Enumeration of contributor types in decision derivation."""

    IDENTITY_CLASS = "identity_class"
    POLICY = "policy"
    WORKLOAD = "workload"
    RESOURCE = "resource"


@dataclass
class TimeWindow:
    """Time window for metric collection."""

    start: datetime
    end: datetime

    def to_dict(self) -> Dict[str, str]:
        """Convert to ISO 8601 dictionary."""
        return {
            "start": self.start.isoformat(),
            "end": self.end.isoformat(),
        }


@dataclass
class InputSpecification:
    """Specification of inputs consumed to derive decision."""

    source_tables: List[str]  # e.g., ["value_plane.operator_ledger_v2", "value_plane.cost_model"]
    query_files: List[str]  # e.g., ["data/queries/civ_interfaces/civ_snapshot.sql"]
    parameters: Dict[str, Any]  # e.g., {"identity_class": "workload", "time_window_minutes": 60}

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "source_tables": self.source_tables,
            "query_files": self.query_files,
            "parameters": self.parameters,
        }


@dataclass
class DerivedMetrics:
    """Derived metrics computed from source data."""

    utilization_percent: float  # 0.0 – 100.0
    denial_pressure: float  # 0.0 – 1.0 (normalized)
    minutes_to_breach: Optional[int] = None  # Time until threshold exceeded, or None if stable
    confidence_interval: Optional[Dict[str, float]] = None  # {"low": float, "high": float}

    def __post_init__(self):
        """Validate metric ranges."""
        if not 0.0 <= self.utilization_percent <= 100.0:
            raise ValueError(f"utilization_percent must be in [0.0, 100.0], got {self.utilization_percent}")
        if not 0.0 <= self.denial_pressure <= 1.0:
            raise ValueError(f"denial_pressure must be in [0.0, 1.0], got {self.denial_pressure}")
        if self.confidence_interval is not None:
            if "low" not in self.confidence_interval or "high" not in self.confidence_interval:
                raise ValueError("confidence_interval must have 'low' and 'high' keys")

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "utilization_percent": self.utilization_percent,
            "denial_pressure": self.denial_pressure,
            "minutes_to_breach": self.minutes_to_breach,
            "confidence_interval": self.confidence_interval,
        }


@dataclass
class Contributor:
    """Single contributor to decision derivation."""

    contributor_type: ContributorType
    contributor_id: str
    contribution_percent: float

    def __post_init__(self):
        """Validate contribution percentage."""
        if not 0.0 <= self.contribution_percent <= 100.0:
            raise ValueError(f"contribution_percent must be in [0.0, 100.0], got {self.contribution_percent}")

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "contributor_type": self.contributor_type.value,
            "contributor_id": self.contributor_id,
            "contribution_percent": self.contribution_percent,
        }


@dataclass
class CounterfactualSensitivity:
    """Sensitivity analysis: what would change this outcome?"""

    increase_budget_by: Dict[str, Any]  # {"delta": float, "effect": str}
    reduce_load_by: Dict[str, Any]  # {"delta": float, "effect": str}
    enforce_now: Dict[str, Any]  # {"hypothetical_effect": str}

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "increase_budget_by": self.increase_budget_by,
            "reduce_load_by": self.reduce_load_by,
            "enforce_now": self.enforce_now,
        }


@dataclass
class Recommendation:
    """Recommendation derived from decision."""

    text: str
    confidence: float  # 0.0 – 1.0

    def __post_init__(self):
        """Validate confidence."""
        if not 0.0 <= self.confidence <= 1.0:
            raise ValueError(f"confidence must be in [0.0, 1.0], got {self.confidence}")

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "text": self.text,
            "confidence": self.confidence,
        }


@dataclass
class DecisionRecord:
    """
    Canonical decision record.

    Global Invariant: This record is strictly advisory. It contains:
    - Decision ID (UUID)
    - Decision type (budget, policy, denial, composite)
    - Generation timestamp
    - Metric collection window
    - Input specification (source tables, queries, parameters)
    - Derived metrics (utilization, denial pressure, time-to-breach)
    - Dominant contributors (who/what drives this)
    - Counterfactual sensitivity (what would change it)
    - Recommendation (human-readable, with confidence)
    - Classification: "ADVISORY_ONLY" (immutable)
    - Enforcement prohibition flag: true (immutable)
    - Provenance hash: sha256 deterministic over all inputs/metrics/contributors

    The provenance_hash ensures that given identical inputs, the same
    DecisionRecord is reproduced. This enables replay, audit, and signature
    verification without requiring database re-query.
    """

    decision_id: UUID
    decision_type: DecisionType
    generated_at: datetime
    time_window: TimeWindow
    inputs: InputSpecification
    derived_metrics: DerivedMetrics
    dominant_contributors: List[Contributor]
    counterfactual_sensitivity: CounterfactualSensitivity
    recommendation: Recommendation
    classification: str = field(default="ADVISORY_ONLY", init=False)
    enforcement_prohibited: bool = field(default=True, init=False)
    provenance_hash: str = field(default="", init=False)
    signature: str = field(default="", init=False)  # Phase 7: Ed25519 signature (hex-encoded)
    signing_key_id: str = field(default="governance-signer-v1", init=False)  # Phase 7: Key ID for rotation
    ccid: str = field(default="", init=False)  # Phase 8: Causal Correlation ID (for observability)
    counterfactuals: List[Any] = field(default_factory=list)  # Populated in Phase E
    inertia: Optional[Any] = field(default=None)  # Populated in Phase E

    def __post_init__(self):
        """Compute provenance hash after all fields are set."""
        self.provenance_hash = self.compute_provenance_hash()

    def canonical_form(self) -> str:
        """Produce canonical JSON for cryptographic signing.

        Deterministic JSON representation using sorted keys and no whitespace.
        Same input always produces identical output, enabling signature verification.

        Returns:
            Canonical JSON string suitable for Ed25519 signing
        """
        # Build payload with all fields needed for cryptographic binding
        payload = {
            "decision_id": str(self.decision_id),
            "decision_type": self.decision_type.value,
            "generated_at": self.generated_at.isoformat(),
            "time_window": self.time_window.to_dict(),
            "inputs": self.inputs.to_dict(),
            "derived_metrics": self.derived_metrics.to_dict(),
            "dominant_contributors": [c.to_dict() for c in self.dominant_contributors],
            "counterfactual_sensitivity": self.counterfactual_sensitivity.to_dict(),
            "recommendation": self.recommendation.to_dict(),
            "classification": self.classification,
            "enforcement_prohibited": self.enforcement_prohibited,
            "provenance_hash": self.provenance_hash,
        }

        # Deterministic JSON: sorted keys, no extra whitespace
        return json.dumps(payload, sort_keys=True, separators=(",", ":"))

    def compute_provenance_hash(self) -> str:
        """
        Compute SHA256 hash over inputs, derived_metrics, and contributors.

        This hash is deterministic: given identical inputs, the same hash
        is produced. This enables replay verification and cryptographic
        attribution.

        Hash includes:
        - inputs (source tables, queries, parameters)
        - derived_metrics (utilization, denial_pressure, minutes_to_breach, confidence)
        - dominant_contributors (all contributors and their percentages)
        - counterfactual_sensitivity (hypothetical deltas and effects)
        - recommendation (text and confidence)

        Hash does NOT include:
        - decision_id (unique per run, breaks determinism)
        - generated_at (timestamp, breaks determinism)
        - classification (constant)
        - enforcement_prohibited (constant)

        This ensures the hash remains stable when the same analysis is
        re-run with the same data.
        """
        payload = {
            "inputs": self.inputs.to_dict(),
            "derived_metrics": self.derived_metrics.to_dict(),
            "dominant_contributors": [c.to_dict() for c in self.dominant_contributors],
            "counterfactual_sensitivity": self.counterfactual_sensitivity.to_dict(),
            "recommendation": self.recommendation.to_dict(),
        }

        # Deterministic JSON serialization (sorted keys, no whitespace)
        payload_json = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(payload_json.encode()).hexdigest()

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "decision_id": str(self.decision_id),
            "decision_type": self.decision_type.value,
            "generated_at": self.generated_at.isoformat(),
            "time_window": self.time_window.to_dict(),
            "inputs": self.inputs.to_dict(),
            "derived_metrics": self.derived_metrics.to_dict(),
            "dominant_contributors": [c.to_dict() for c in self.dominant_contributors],
            "counterfactual_sensitivity": self.counterfactual_sensitivity.to_dict(),
            "recommendation": self.recommendation.to_dict(),
            "classification": self.classification,
            "enforcement_prohibited": self.enforcement_prohibited,
            "provenance_hash": self.provenance_hash,
            "signature": self.signature,
            "signing_key_id": self.signing_key_id,
            "ccid": self.ccid,
            "counterfactuals": self.counterfactuals,
            "inertia": self.inertia,
        }

    def to_json_str(self) -> str:
        """Serialize to JSON string."""
        return json.dumps(self.to_dict(), indent=2)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "DecisionRecord":
        """Reconstruct DecisionRecord from dictionary.

        Enables loading DecisionRecord artifacts from disk.
        Validates inputs to prevent injection attacks.
        """
        from uuid import UUID

        # Validate table names (schema.table format)
        VALID_TABLE_PATTERN = re.compile(r"^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$")
        for table in data["inputs"]["source_tables"]:
            if not isinstance(table, str) or not VALID_TABLE_PATTERN.match(table):
                raise ValueError(f"Invalid source table name: {table}")

        # Validate query file paths (data/queries/ directory only)
        VALID_FILE_PATTERN = re.compile(r"^(data/)?queries/[a-z_/]+\.sql$")
        for query_file in data["inputs"]["query_files"]:
            if not isinstance(query_file, str) or not VALID_FILE_PATTERN.match(query_file):
                raise ValueError(f"Invalid query file path: {query_file}")

        # Validate parameter keys (no dunder attributes)
        for key, value in data["inputs"]["parameters"].items():
            if not isinstance(key, str) or key.startswith("__"):
                raise ValueError(f"Invalid parameter key: {key}")
            if not isinstance(value, (str, int, float, bool, type(None))):
                raise ValueError(f"Invalid parameter value type for {key}: {type(value)}")

        # Validate metrics are in reasonable bounds
        utilization = data["derived_metrics"]["utilization_percent"]
        if not isinstance(utilization, (int, float)) or utilization < 0 or utilization > 1000:
            raise ValueError(f"Invalid utilization_percent: {utilization}")

        denial_pressure = data["derived_metrics"]["denial_pressure"]
        if not isinstance(denial_pressure, (int, float)) or denial_pressure < 0 or denial_pressure > 1.0:
            raise ValueError(f"Invalid denial_pressure: {denial_pressure}")

        # Phase 7: Validate signature format (hex-encoded, 128 characters for Ed25519)
        signature = data.get("signature", "")
        if signature and not isinstance(signature, str):
            raise ValueError(f"Invalid signature type: {type(signature)}")
        if signature and (len(signature) != 128 or not all(c in "0123456789abcdef" for c in signature)):
            raise ValueError(f"Invalid signature format: {signature}")

        record = cls(
            decision_id=UUID(data["decision_id"]),
            decision_type=DecisionType(data["decision_type"]),
            generated_at=datetime.fromisoformat(data["generated_at"]),
            time_window=TimeWindow(
                start=datetime.fromisoformat(data["time_window"]["start"]),
                end=datetime.fromisoformat(data["time_window"]["end"]),
            ),
            inputs=InputSpecification(
                source_tables=data["inputs"]["source_tables"],
                query_files=data["inputs"]["query_files"],
                parameters=data["inputs"]["parameters"],
            ),
            derived_metrics=DerivedMetrics(
                utilization_percent=data["derived_metrics"]["utilization_percent"],
                denial_pressure=data["derived_metrics"]["denial_pressure"],
                minutes_to_breach=data["derived_metrics"].get("minutes_to_breach"),
                confidence_interval=data["derived_metrics"].get("confidence_interval"),
            ),
            dominant_contributors=[
                Contributor(
                    contributor_type=ContributorType(c["contributor_type"]),
                    contributor_id=c["contributor_id"],
                    contribution_percent=c["contribution_percent"],
                )
                for c in data["dominant_contributors"]
            ],
            counterfactual_sensitivity=CounterfactualSensitivity(
                increase_budget_by=data["counterfactual_sensitivity"]["increase_budget_by"],
                reduce_load_by=data["counterfactual_sensitivity"]["reduce_load_by"],
                enforce_now=data["counterfactual_sensitivity"]["enforce_now"],
            ),
            recommendation=Recommendation(
                text=data["recommendation"]["text"],
                confidence=data["recommendation"]["confidence"],
            ),
        )

        # Phase 7: Set signature and signing_key_id if present
        if signature:
            record.signature = signature
        if "signing_key_id" in data:
            record.signing_key_id = data["signing_key_id"]

        return record
