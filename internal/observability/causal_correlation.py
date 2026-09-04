"""
Causal Correlation ID (CCID) — Deterministic binding for observability

Phase 8: Latticed Observability

CCID is a deterministic identifier that binds all signals (logs, metrics, traces)
to sealed governance artifacts. It enables authoritative causal reconstruction.

CCID Construction:
    ccid = SHA256(decision_hash || aas_hash || scope || identity || issued_at)

Properties:
- Deterministic: Same inputs always produce same CCID
- Unique: Different governance paths produce different CCIDs
- Immutable: Once computed, never changes
- Verifiable: Anyone with artifacts can recompute and verify

Global Invariant: Signals without valid CCID are non-authoritative.
"""

import hashlib
import json
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, Optional, Union


def compute_ccid(
    decision_hash: str,
    aas_hash: str,
    scope: Dict[str, str],
    identity: str,
    issued_at: Union[datetime, str],
) -> str:
    """Compute Causal Correlation ID (CCID).

    CCID binds all observability signals to sealed governance artifacts.
    It is the authoritative correlation key for causal reconstruction.

    Args:
        decision_hash: DecisionRecord.provenance_hash (immutable)
        aas_hash: AllowedActionSet.provenance_hash (immutable)
        scope: Enforcement scope {"namespace": "...", "cluster": "..."}
        identity: SPIFFE ID performing action
        issued_at: Timestamp when AAS was issued (datetime or ISO string)

    Returns:
        Hex-encoded SHA256 hash (64 chars)

    Example:
        ccid = compute_ccid(
            decision_hash="abc123...",
            aas_hash="def456...",
            scope={"namespace": "default", "cluster": "threadforge"},
            identity="spiffe://<SPIFFE_TRUST_DOMAIN>/ns/default/sa/workload",
            issued_at=datetime(2026, 1, 30, 12, 0, 0),
        )
        # ccid = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    """
    # Convert issued_at to string if datetime
    if isinstance(issued_at, datetime):
        issued_at_str = issued_at.isoformat()
    else:
        issued_at_str = issued_at

    # Canonical payload (sorted keys for determinism)
    payload = {
        "decision_hash": decision_hash,
        "aas_hash": aas_hash,
        "scope": scope,
        "identity": identity,
        "issued_at": issued_at_str,
    }

    # Deterministic JSON (sorted keys, no whitespace)
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))

    # SHA256 hash
    return hashlib.sha256(canonical.encode()).hexdigest()


def verify_ccid(
    ccid: str,
    decision_hash: str,
    aas_hash: str,
    scope: Dict[str, str],
    identity: str,
    issued_at: Union[datetime, str],
) -> bool:
    """Verify CCID matches expected value.

    Recomputes CCID from inputs and checks if it matches provided CCID.

    Args:
        ccid: CCID to verify
        decision_hash: DecisionRecord.provenance_hash
        aas_hash: AllowedActionSet.provenance_hash
        scope: Enforcement scope
        identity: SPIFFE ID
        issued_at: AAS issuance timestamp (datetime or ISO string)

    Returns:
        True if CCID matches, False otherwise
    """
    expected_ccid = compute_ccid(
        decision_hash=decision_hash,
        aas_hash=aas_hash,
        scope=scope,
        identity=identity,
        issued_at=issued_at,
    )
    return ccid == expected_ccid


@dataclass
class CausalSignal:
    """Structured signal with CCID binding.

    All observability signals (logs, metrics, traces) must include CCID
    to be considered authoritative.
    """

    ccid: str
    signal_type: str  # "log" | "metric" | "trace"
    event_type: str  # "decision" | "aas_generation" | "enforcement" | "meta_governance"
    timestamp: datetime
    decision_hash: str
    aas_hash: Optional[str] = None  # Not present for decision-only events
    scope: Optional[Dict[str, str]] = None
    identity: Optional[str] = None
    payload: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "ccid": self.ccid,
            "signal_type": self.signal_type,
            "event_type": self.event_type,
            "timestamp": self.timestamp.isoformat(),
            "decision_hash": self.decision_hash,
            "aas_hash": self.aas_hash,
            "scope": self.scope,
            "identity": self.identity,
            "payload": self.payload,
        }

    def is_authoritative(self) -> bool:
        """Check if signal is authoritative.

        Signal is authoritative if:
        - CCID is present (non-empty)
        - CCID is valid format (64 hex chars)
        - decision_hash is present
        """
        if not self.ccid or len(self.ccid) != 64:
            return False
        if not all(c in "0123456789abcdef" for c in self.ccid):
            return False
        if not self.decision_hash:
            return False
        return True


def emit_causal_log(
    ccid: str,
    event_type: str,
    decision_hash: str,
    aas_hash: Optional[str] = None,
    scope: Optional[Dict[str, str]] = None,
    identity: Optional[str] = None,
    payload: Optional[Dict[str, Any]] = None,
    log_path: str = "artifacts/logs/observability_causal.jsonl",
) -> None:
    """Emit log with CCID binding.

    All logs must include CCID for authoritative causal reconstruction.

    Args:
        ccid: Causal Correlation ID
        event_type: Type of event (decision, aas_generation, enforcement, etc.)
        decision_hash: DecisionRecord.provenance_hash
        aas_hash: AllowedActionSet.provenance_hash (if applicable)
        scope: Enforcement scope (if applicable)
        identity: SPIFFE ID (if applicable)
        payload: Additional event data
        log_path: Path to causal log file
    """
    import os

    signal = CausalSignal(
        ccid=ccid,
        signal_type="log",
        event_type=event_type,
        timestamp=datetime.now(),
        decision_hash=decision_hash,
        aas_hash=aas_hash,
        scope=scope,
        identity=identity,
        payload=payload,
    )

    # Write to causal log
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a") as f:
        f.write(json.dumps(signal.to_dict()) + "\n")


def emit_causal_metric(
    ccid: str,
    metric_name: str,
    metric_value: float,
    decision_hash: str,
    aas_hash: Optional[str] = None,
    scope: Optional[Dict[str, str]] = None,
    identity: Optional[str] = None,
    tags: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    """Emit metric with CCID binding.

    Metrics must include CCID for authoritative causal reconstruction.

    Args:
        ccid: Causal Correlation ID
        metric_name: Metric name (e.g., "governance.aas.issued")
        metric_value: Metric value
        decision_hash: DecisionRecord.provenance_hash
        aas_hash: AllowedActionSet.provenance_hash (if applicable)
        scope: Enforcement scope (if applicable)
        identity: SPIFFE ID (if applicable)
        tags: Additional metric tags

    Returns:
        Metric dictionary (for OTEL emission or storage)
    """
    signal = {
        "ccid": ccid,
        "metric_name": metric_name,
        "metric_value": metric_value,
        "timestamp": datetime.now().isoformat(),
        "decision_hash": decision_hash,
        "aas_hash": aas_hash,
        "scope": scope,
        "identity": identity,
        "tags": tags or {},
    }

    if is_signal_authoritative(signal):
        scope_data = scope or {}
        tag_data = tags or {}

        labels = {
            "ccid": ccid,
            "scope_namespace": str(scope_data.get("namespace", "unknown")),
            "scope_cluster": str(scope_data.get("cluster", "unknown")),
            "scope_resource_type": str(scope_data.get("resource_type", "unknown")),
            "identity": str(identity or "unknown"),
            "action": str(tag_data.get("action", "unknown")),
            "result": str(tag_data.get("result", "unknown")),
            "reason": str(tag_data.get("reason", "unknown")),
            "decision_hash": str(decision_hash),
            "aas_hash": str(aas_hash or "unknown"),
        }

        try:
            from runtime.telemetry.prometheus_exporter import observe_governance_metric

            observe_governance_metric(metric_name, metric_value, labels)
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                "observe_governance_metric (causal correlation)", e
            )  # nosec B110: Metrics are best-effort and must not block governance execution

    return signal


def is_signal_authoritative(signal: Dict[str, Any]) -> bool:
    """Check if signal is authoritative.

    Signal must have valid CCID and be bound to sealed artifacts.

    Args:
        signal: Signal dictionary (from log, metric, or trace)

    Returns:
        True if authoritative, False otherwise
    """
    ccid = signal.get("ccid", "")
    if not ccid or len(ccid) != 64:
        return False
    if not all(c in "0123456789abcdef" for c in ccid):
        return False
    if not signal.get("decision_hash"):
        return False
    return True
