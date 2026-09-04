"""
Authoritative Observation Plane — Causal Reconstruction from Sealed Artifacts

Phase 8: Latticed Observability

Read-only deterministic index over sealed JSONL logs and artifacts.
Reconstructs: Decision → AAS → Constraint → Enforcement → Audit

All reconstruction uses CCID (Causal Correlation ID) as binding key.
Signals without valid CCID are non-authoritative and excluded.

Global Invariant: Observation is authoritative only if causally bound to sealed artifacts.
"""

import json
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

from internal.observability.causal_correlation import is_signal_authoritative


@dataclass
class CausalChain:
    """Reconstructed causal chain for a single CCID.

    All events in chain are bound by same CCID.
    """

    ccid: str
    decision_hash: str
    aas_hash: Optional[str]
    scope: Optional[Dict[str, str]]
    identity: Optional[str]

    # Events in order of occurrence
    decision_event: Optional[Dict[str, Any]] = None
    aas_generation_event: Optional[Dict[str, Any]] = None
    enforcement_events: List[Dict[str, Any]] = field(default_factory=list)
    meta_governance_events: List[Dict[str, Any]] = field(default_factory=list)

    def __post_init__(self):
        if self.enforcement_events is None:
            self.enforcement_events = []
        if self.meta_governance_events is None:
            self.meta_governance_events = []

    def is_complete(self) -> bool:
        """Check if chain has all required events.

        Complete chain: decision → aas_generation → enforcement
        """
        return (
            self.decision_event is not None
            and self.aas_generation_event is not None
            and len(self.enforcement_events) > 0
        )

    def is_authoritative(self) -> bool:
        """Check if all events in chain are authoritative.

        Authoritative: all events have valid CCID and match sealed hashes.
        """
        events = [self.decision_event, self.aas_generation_event] + self.enforcement_events

        for event in events:
            if event is None:
                continue
            if not is_signal_authoritative(event):
                return False

        return True

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON output."""
        return {
            "ccid": self.ccid,
            "decision_hash": self.decision_hash,
            "aas_hash": self.aas_hash,
            "scope": self.scope,
            "identity": self.identity,
            "decision_event": self.decision_event,
            "aas_generation_event": self.aas_generation_event,
            "enforcement_events": self.enforcement_events,
            "meta_governance_events": self.meta_governance_events,
            "is_complete": self.is_complete(),
            "is_authoritative": self.is_authoritative(),
        }


class ObservationPlane:
    """Authoritative observation plane for governance system.

    Reads sealed JSONL logs and reconstructs causal chains using CCID.

    Properties:
    - Read-only (no mutations)
    - Deterministic (same logs → same reconstruction)
    - Authoritative-only (rejects non-authoritative signals)
    - CCID-bound (all events correlated by CCID)
    """

    def __init__(
        self,
        causal_log_path: str = "artifacts/logs/observability_causal.jsonl",
        governance_log_path: str = "artifacts/logs/governance_aas.jsonl",
    ):
        """Initialize observation plane.

        Args:
            causal_log_path: Path to Phase 8 causal log (CCID-bound)
            governance_log_path: Path to Phase 1-7 governance log (legacy)
        """
        self.causal_log_path = causal_log_path
        self.governance_log_path = governance_log_path

        # Index: ccid -> CausalChain
        self._chains: Dict[str, CausalChain] = {}

        # Index: decision_hash -> List[ccid]
        self._decision_index: Dict[str, List[str]] = defaultdict(list)

        # Index: aas_hash -> List[ccid]
        self._aas_index: Dict[str, List[str]] = defaultdict(list)

        # Track orphan signals (missing CCID or invalid)
        self._orphan_signals: List[Dict[str, Any]] = []

    def load(self) -> None:
        """Load and index all causal logs.

        Reads sealed JSONL, filters non-authoritative signals, builds CCID index.
        """
        # Load Phase 8 causal logs (CCID-bound)
        if Path(self.causal_log_path).exists():
            with open(self.causal_log_path, "r") as f:
                for line in f:
                    if not line.strip():
                        continue

                    signal = json.loads(line)

                    # Filter non-authoritative signals
                    if not is_signal_authoritative(signal):
                        self._orphan_signals.append(signal)
                        continue

                    ccid = signal["ccid"]
                    event_type = signal.get("event_type", "unknown")

                    # Create or update chain
                    if ccid not in self._chains:
                        self._chains[ccid] = CausalChain(
                            ccid=ccid,
                            decision_hash=signal["decision_hash"],
                            aas_hash=signal.get("aas_hash"),
                            scope=signal.get("scope"),
                            identity=signal.get("identity"),
                        )

                    chain = self._chains[ccid]

                    # Add event to chain
                    if event_type == "decision":
                        chain.decision_event = signal
                    elif event_type == "aas_generation":
                        chain.aas_generation_event = signal
                        if signal.get("aas_hash"):
                            self._aas_index[signal["aas_hash"]].append(ccid)
                    elif event_type == "enforcement":
                        chain.enforcement_events.append(signal)
                    elif event_type == "meta_governance":
                        chain.meta_governance_events.append(signal)

                    # Index by decision hash
                    self._decision_index[signal["decision_hash"]].append(ccid)

    def get_chain_by_ccid(self, ccid: str) -> Optional[CausalChain]:
        """Get causal chain by CCID.

        Args:
            ccid: Causal Correlation ID

        Returns:
            CausalChain if found, None otherwise
        """
        return self._chains.get(ccid)

    def get_chains_by_decision_hash(self, decision_hash: str) -> List[CausalChain]:
        """Get all causal chains for a decision hash.

        Args:
            decision_hash: DecisionRecord.provenance_hash

        Returns:
            List of CausalChain instances
        """
        ccids = self._decision_index.get(decision_hash, [])
        return [self._chains[ccid] for ccid in ccids]

    def get_chains_by_aas_hash(self, aas_hash: str) -> List[CausalChain]:
        """Get all causal chains for an AAS hash.

        Args:
            aas_hash: AllowedActionSet.provenance_hash

        Returns:
            List of CausalChain instances
        """
        ccids = self._aas_index.get(aas_hash, [])
        return [self._chains[ccid] for ccid in ccids]

    def get_all_chains(self) -> List[CausalChain]:
        """Get all causal chains.

        Returns:
            List of all CausalChain instances
        """
        return list(self._chains.values())

    def get_authoritative_chains(self) -> List[CausalChain]:
        """Get only authoritative chains.

        Filters out chains with non-authoritative signals.

        Returns:
            List of authoritative CausalChain instances
        """
        return [chain for chain in self._chains.values() if chain.is_authoritative()]

    def get_orphan_signals(self) -> List[Dict[str, Any]]:
        """Get all orphan signals (non-authoritative).

        Orphan signals are missing CCID or have invalid format.

        Returns:
            List of orphan signal dictionaries
        """
        return self._orphan_signals

    def count_chains(self) -> Dict[str, int]:
        """Get chain statistics.

        Returns:
            Dictionary with counts
        """
        total = len(self._chains)
        authoritative = len(self.get_authoritative_chains())
        complete = len([c for c in self._chains.values() if c.is_complete()])
        incomplete = total - complete
        orphans = len(self._orphan_signals)

        return {
            "total_chains": total,
            "authoritative_chains": authoritative,
            "complete_chains": complete,
            "incomplete_chains": incomplete,
            "orphan_signals": orphans,
        }

    def reconstruct_full_causal_graph(self) -> Dict[str, Any]:
        """Reconstruct full causal graph from all chains.

        Returns:
            Dictionary with full causal graph structure
        """
        chains = self.get_all_chains()

        return {
            "total_chains": len(chains),
            "authoritative_chains": len(self.get_authoritative_chains()),
            "chains": [chain.to_dict() for chain in chains],
            "orphan_signals": self._orphan_signals,
            "statistics": self.count_chains(),
        }

    def export_json(self, output_path: str) -> None:
        """Export causal graph to JSON file.

        Args:
            output_path: Path to output JSON file
        """
        graph = self.reconstruct_full_causal_graph()

        with open(output_path, "w") as f:
            json.dump(graph, f, indent=2)


def query_causal_chain(
    ccid: Optional[str] = None,
    decision_hash: Optional[str] = None,
    aas_hash: Optional[str] = None,
    causal_log_path: str = "artifacts/logs/observability_causal.jsonl",
) -> Dict[str, Any]:
    """Query causal chain by CCID, decision hash, or AAS hash.

    Convenience function for one-query reconstruction.

    Args:
        ccid: Causal Correlation ID
        decision_hash: DecisionRecord.provenance_hash
        aas_hash: AllowedActionSet.provenance_hash
        causal_log_path: Path to causal log

    Returns:
        Dictionary with query results
    """
    plane = ObservationPlane(causal_log_path=causal_log_path)
    plane.load()

    if ccid:
        chain = plane.get_chain_by_ccid(ccid)
        return {"query": "ccid", "result": chain.to_dict() if chain else None}

    if decision_hash:
        chains = plane.get_chains_by_decision_hash(decision_hash)
        return {"query": "decision_hash", "result": [c.to_dict() for c in chains]}

    if aas_hash:
        chains = plane.get_chains_by_aas_hash(aas_hash)
        return {"query": "aas_hash", "result": [c.to_dict() for c in chains]}

    return {"query": "none", "result": None}
