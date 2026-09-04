# Path: runtime/identity/delegation_store.py
"""Delegation store for managing active delegations.

Phase 9: Delegation, Revocation, and Blast-Radius Control
Stores active delegations, enforces expiry, supports immediate revocation.

Phase A: Delegation persistence via PostgreSQL (restart-safe, immutable ledger)
"""

from __future__ import annotations

import os
import threading
from datetime import datetime, timezone
from typing import Dict, List, Set

from runtime.identity.capabilities import CapabilitySet
from runtime.identity.context import IdentityContext
from runtime.identity.delegation import DelegatedCapability
from runtime.identity.delegation_persistence import DelegationPersistence
from runtime.identity.identity_graph import get_identity_graph
from runtime.ledger.operator_ledger import OperatorLedger


class DelegationStore:
    """Thread-safe store for delegation management.

    Responsibilities:
    - Store active delegations
    - Enforce expiry
    - Support immediate revocation
    - Return effective capabilities for delegates
    """

    def __init__(self):
        self._delegations: Dict[str, DelegatedCapability] = {}
        self._by_delegate: Dict[str, Set[str]] = {}  # delegate_spiffe_id -> set of delegation_ids
        self._by_source: Dict[str, Set[str]] = {}  # source_spiffe_id -> set of delegation_ids
        self._lock = threading.RLock()
        self._ledger = OperatorLedger()
        self._identity_graph = get_identity_graph()

        # Phase A: Initialize persistence layer
        # Expects environment variables:
        #   POSTGRES_USER (default: threadforge_operator)
        #   POSTGRES_PASSWORD (default: threadforge)
        #   POSTGRES_HOST (default: localhost)
        #   POSTGRES_PORT (default: 5432)
        # Or direct connection string via THREADFORGE_DELEGATIONS_DB_URL
        db_url = os.environ.get("THREADFORGE_DELEGATIONS_DB_URL")
        if not db_url:
            pg_user = os.environ.get("POSTGRES_USER", "threadforge_operator")
            pg_password = os.environ.get("POSTGRES_PASSWORD", "threadforge")
            pg_host = os.environ.get("POSTGRES_HOST", "localhost")
            pg_port = os.environ.get("POSTGRES_PORT", "5432")
            db_url = f"postgresql://{pg_user}:{pg_password}@{pg_host}:{pg_port}/threadforge"

        self._persistence = DelegationPersistence(db_url)

        # Create schema on init (idempotent)
        try:
            self._persistence.create_schema()
        except Exception as e:
            # Log but don't fail - schema may already exist
            import sys

            print(f"Warning: Failed to create persistence schema: {e}", file=sys.stderr)

        # Rehydrate active delegations from persistence (restart-safe)
        try:
            rehydrated = self._persistence.load_active_delegations()
            for delegation in rehydrated:
                self._delegations[delegation.delegation_id] = delegation

                # Rebuild indexes
                if delegation.delegate_spiffe_id not in self._by_delegate:
                    self._by_delegate[delegation.delegate_spiffe_id] = set()
                self._by_delegate[delegation.delegate_spiffe_id].add(delegation.delegation_id)

                if delegation.source_spiffe_id not in self._by_source:
                    self._by_source[delegation.source_spiffe_id] = set()
                self._by_source[delegation.source_spiffe_id].add(delegation.delegation_id)

                # Rebuild identity graph edges
                self._identity_graph.add_delegation_edge(delegation)
        except Exception as e:
            # Log warning but continue - in-memory store will start empty
            import sys

            print(f"Warning: Failed to rehydrate delegations: {e}", file=sys.stderr)

    def _emit_delegation_event(
        self,
        event_type: str,
        delegation: DelegatedCapability,
        source_identity: IdentityContext,
        additional_payload: dict | None = None,
    ) -> None:
        """Emit a delegation lifecycle event to the ledger."""
        payload = {
            "type": f"delegation.{event_type}",
            "delegation_id": delegation.delegation_id,
            "source_spiffe_id": delegation.source_spiffe_id,
            "delegate_spiffe_id": delegation.delegate_spiffe_id,
            "capabilities": list(delegation.capabilities),
            "issued_at": delegation.issued_at.isoformat(),
            "expires_at": delegation.expires_at.isoformat(),
            "justification": delegation.justification,
            "policy_source": delegation.policy_source,
            "status": "ok",
        }

        if delegation.revoked_at:
            payload["revoked_at"] = delegation.revoked_at.isoformat()

        if additional_payload:
            payload.update(additional_payload)

        try:
            self._ledger.record_event(payload)
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                "delegation ledger.record_event", e
            )  # nosec B110: Ledger writes for delegation tracking are best-effort in some envs and must not fail core ops

    def store_delegation(self, delegation: DelegatedCapability, source_identity: IdentityContext) -> None:
        """Store a new delegation."""
        with self._lock:
            self._delegations[delegation.delegation_id] = delegation

            # Index by delegate
            if delegation.delegate_spiffe_id not in self._by_delegate:
                self._by_delegate[delegation.delegate_spiffe_id] = set()
            self._by_delegate[delegation.delegate_spiffe_id].add(delegation.delegation_id)

            # Index by source
            if delegation.source_spiffe_id not in self._by_source:
                self._by_source[delegation.source_spiffe_id] = set()
            self._by_source[delegation.source_spiffe_id].add(delegation.delegation_id)

            # Record in identity graph
            self._identity_graph.add_delegation_edge(delegation)

            # Emit ledger event
            self._emit_delegation_event("issued", delegation, source_identity)

            # Phase A: Persist to database (fail-closed: if DB fails, delegation fails)
            try:
                self._persistence.persist_delegation(delegation)
            except Exception as e:
                # Remove from in-memory store and re-raise (fail-closed)
                del self._delegations[delegation.delegation_id]
                if delegation.delegation_id in self._by_delegate.get(delegation.delegate_spiffe_id, set()):
                    self._by_delegate[delegation.delegate_spiffe_id].discard(delegation.delegation_id)
                if delegation.delegation_id in self._by_source.get(delegation.source_spiffe_id, set()):
                    self._by_source[delegation.source_spiffe_id].discard(delegation.delegation_id)
                self._identity_graph.remove_delegation_edge(delegation.delegation_id)
                raise RuntimeError(f"Failed to persist delegation {delegation.delegation_id}: {e}") from e

    def get_delegation(self, delegation_id: str) -> DelegatedCapability | None:
        """Retrieve a delegation by ID."""
        with self._lock:
            return self._delegations.get(delegation_id)

    def get_active_delegations_for_delegate(self, delegate_spiffe_id: str) -> List[DelegatedCapability]:
        """Get all active delegations for a delegate."""
        with self._lock:
            delegation_ids = self._by_delegate.get(delegate_spiffe_id, set())
            active_delegations = []

            for delegation_id in delegation_ids:
                delegation = self._delegations.get(delegation_id)
                if delegation and delegation.is_active:
                    active_delegations.append(delegation)

            return active_delegations

    def get_all_delegations_from_source(self, source_spiffe_id: str) -> List[DelegatedCapability]:
        """Get all delegations issued by a source (active and inactive)."""
        with self._lock:
            delegation_ids = self._by_source.get(source_spiffe_id, set())
            return [self._delegations[did] for did in delegation_ids if did in self._delegations]

    def revoke_delegation(self, delegation_id: str, source_identity: IdentityContext) -> bool:
        """Revoke a delegation by ID. Returns True if found and revoked."""
        with self._lock:
            delegation = self._delegations.get(delegation_id)
            if delegation and not delegation.is_revoked:
                # Create revoked version
                revoked_at = datetime.now(timezone.utc)
                revoked_delegation = DelegatedCapability(
                    delegation_id=delegation.delegation_id,
                    source_spiffe_id=delegation.source_spiffe_id,
                    delegate_spiffe_id=delegation.delegate_spiffe_id,
                    capabilities=delegation.capabilities,
                    issued_at=delegation.issued_at,
                    expires_at=delegation.expires_at,
                    justification=delegation.justification,
                    policy_source=delegation.policy_source,
                    revoked_at=revoked_at,
                )
                self._delegations[delegation_id] = revoked_delegation

                # Emit delegation revoked event
                self._emit_delegation_event("revoked", revoked_delegation, source_identity)

                # Remove from identity graph (revoked delegations are removed from graph)
                self._identity_graph.remove_delegation_edge(delegation_id)

                # Phase A: Mark revoked in persistence (fail-closed: if DB fails, revocation fails)
                try:
                    self._persistence.mark_revoked(delegation_id, revoked_at)
                except Exception as e:
                    # Revert in-memory change and re-raise (fail-closed)
                    self._delegations[delegation_id] = delegation
                    self._identity_graph.add_delegation_edge(delegation)
                    raise RuntimeError(f"Failed to persist revocation for {delegation_id}: {e}") from e

                return True
            return False

    def revoke_all_from_source(self, source_spiffe_id: str, source_identity: IdentityContext) -> int:
        """Revoke all delegations from a source. Returns count of revoked delegations."""
        with self._lock:
            delegation_ids = self._by_source.get(source_spiffe_id, set())
            revoked_count = 0

            for delegation_id in delegation_ids:
                if self.revoke_delegation(delegation_id, source_identity):
                    revoked_count += 1

            return revoked_count

    def cleanup_expired(self) -> int:
        """Remove expired delegations from indexes. Returns count cleaned."""
        with self._lock:
            # Note: We don't actually remove expired delegations from _delegations
            # as they may still be needed for audit. We just clean up indexes.
            now = datetime.now(timezone.utc)
            cleaned_count = 0

            # Clean up delegate index
            for delegate_id in list(self._by_delegate.keys()):
                delegation_ids = self._by_delegate[delegate_id]
                active_ids = set()

                for did in delegation_ids:
                    delegation = self._delegations.get(did)
                    if delegation and delegation.is_active:
                        active_ids.add(did)

                if not active_ids:
                    del self._by_delegate[delegate_id]
                    cleaned_count += len(delegation_ids)
                elif len(active_ids) != len(delegation_ids):
                    self._by_delegate[delegate_id] = active_ids
                    cleaned_count += len(delegation_ids) - len(active_ids)

            # Clean up expired delegations from identity graph
            expired_delegations = [did for did, d in self._delegations.items() if not d.is_active and d.is_expired]
            for did in expired_delegations:
                self._identity_graph.remove_delegation_edge(did)

            return cleaned_count

    def get_effective_capabilities(self, identity: IdentityContext, base_capabilities: CapabilitySet) -> CapabilitySet:
        """Get effective capabilities including active delegations.

        Effective capabilities = base capabilities + active delegations
        """
        with self._lock:
            # Get active delegations for this identity
            active_delegations = self.get_active_delegations_for_delegate(identity.spiffe_id)

            # Combine all capabilities
            effective_capabilities = set(base_capabilities.capabilities)

            for delegation in active_delegations:
                effective_capabilities.update(delegation.capabilities)

            # Use the base policy as primary source, but note delegation influence
            derived_from_policy = base_capabilities.derived_from_policy
            if active_delegations:
                sources = {d.policy_source for d in active_delegations}
                derived_from_policy += f" + delegations({','.join(sorted(sources))})"

            return CapabilitySet(
                identity_spiffe_id=identity.spiffe_id,
                capabilities=frozenset(effective_capabilities),
                derived_from_policy=derived_from_policy,
            )


# Global delegation store instance
_delegation_store = None


def get_delegation_store() -> DelegationStore:
    """Get the global delegation store instance."""
    global _delegation_store
    if _delegation_store is None:
        _delegation_store = DelegationStore()
    return _delegation_store
