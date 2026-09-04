# Path: runtime/identity/identity_graph.py
"""Identity graph for tracking delegation relationships.

Phase 9: Delegation, Revocation, and Blast-Radius Control
Tracks delegation edges for security analysis and incident response.
"""

from __future__ import annotations

import threading
from typing import Dict, List, Set

from runtime.identity.delegation import DelegatedCapability


class IdentityGraph:
    """Graph of identity relationships including delegations.

    Tracks delegation edges for blast-radius analysis and incident response.
    """

    def __init__(self):
        # delegation_id -> DelegatedCapability
        self._delegations: Dict[str, DelegatedCapability] = {}
        # source_spiffe_id -> set of delegation_ids
        self._outgoing_edges: Dict[str, Set[str]] = {}
        # delegate_spiffe_id -> set of delegation_ids
        self._incoming_edges: Dict[str, Set[str]] = {}
        self._lock = threading.RLock()

    def add_delegation_edge(self, delegation: DelegatedCapability) -> None:
        """Add a delegation edge to the graph."""
        with self._lock:
            self._delegations[delegation.delegation_id] = delegation

            # Add outgoing edge from source
            if delegation.source_spiffe_id not in self._outgoing_edges:
                self._outgoing_edges[delegation.source_spiffe_id] = set()
            self._outgoing_edges[delegation.source_spiffe_id].add(delegation.delegation_id)

            # Add incoming edge to delegate
            if delegation.delegate_spiffe_id not in self._incoming_edges:
                self._incoming_edges[delegation.delegate_spiffe_id] = set()
            self._incoming_edges[delegation.delegate_spiffe_id].add(delegation.delegation_id)

    def remove_delegation_edge(self, delegation_id: str) -> bool:
        """Remove a delegation edge from the graph. Returns True if found."""
        with self._lock:
            delegation = self._delegations.get(delegation_id)
            if not delegation:
                return False

            # Remove from outgoing edges
            if delegation.source_spiffe_id in self._outgoing_edges:
                self._outgoing_edges[delegation.source_spiffe_id].discard(delegation_id)
                if not self._outgoing_edges[delegation.source_spiffe_id]:
                    del self._outgoing_edges[delegation.source_spiffe_id]

            # Remove from incoming edges
            if delegation.delegate_spiffe_id in self._incoming_edges:
                self._incoming_edges[delegation.delegate_spiffe_id].discard(delegation_id)
                if not self._incoming_edges[delegation.delegate_spiffe_id]:
                    del self._incoming_edges[delegation.delegate_spiffe_id]

            # Remove delegation
            del self._delegations[delegation_id]
            return True

    def get_delegation_blast_radius(self, source_spiffe_id: str) -> List[str]:
        """Get all identities that could be affected by revoking delegations from source.

        Returns list of SPIFFE IDs that have active delegations from the source.
        """
        with self._lock:
            delegation_ids = self._outgoing_edges.get(source_spiffe_id, set())
            affected_identities = set()

            for delegation_id in delegation_ids:
                delegation = self._delegations.get(delegation_id)
                if delegation and delegation.is_active:
                    affected_identities.add(delegation.delegate_spiffe_id)

            return list(affected_identities)

    def get_delegation_sources(self, delegate_spiffe_id: str) -> List[str]:
        """Get all sources that have delegated authority to this identity.

        Returns list of SPIFFE IDs that have active delegations to the delegate.
        """
        with self._lock:
            delegation_ids = self._incoming_edges.get(delegate_spiffe_id, set())
            sources = set()

            for delegation_id in delegation_ids:
                delegation = self._delegations.get(delegation_id)
                if delegation and delegation.is_active:
                    sources.add(delegation.source_spiffe_id)

            return list(sources)

    def get_all_active_delegations(self) -> List[DelegatedCapability]:
        """Get all active delegations in the graph."""
        with self._lock:
            return [d for d in self._delegations.values() if d.is_active]


# Global identity graph instance
_identity_graph = None


def get_identity_graph() -> IdentityGraph:
    """Get the global identity graph instance."""
    global _identity_graph
    if _identity_graph is None:
        _identity_graph = IdentityGraph()
    return _identity_graph
