"""Phase A: Delegation persistence layer.

Persists delegations to PostgreSQL for restart safety.
Ledger remains the source of truth; persistence is a materialization.
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, List, Optional

from runtime.identity.delegation import DelegatedCapability

log = logging.getLogger("delegation_persistence")


class DelegationPersistence:
    """Persistent storage for delegations using PostgreSQL.

    Schema immutable: one row per capability per delegation.
    Ledger emit + persistence are atomic (fail-closed).
    """

    def __init__(self, connection_string: str):
        """Initialize connection pool.

        Imports psycopg2 only when instantiated (lazy import).
        """
        import psycopg2
        import psycopg2.extras
        from psycopg2.pool import SimpleConnectionPool

        self.psycopg2 = psycopg2
        self.SimpleConnectionPool = SimpleConnectionPool
        self.psycopg2_extras = psycopg2.extras

        """
        Args:
            connection_string: PostgreSQL connection string (psycopg2 format)
        """
        try:
            self.pool: Optional[Any] = self.SimpleConnectionPool(1, 5, connection_string)
        except Exception as e:
            log.warning(f"Failed to initialize delegation persistence: {e}")
            self.pool = None

    def create_schema(self) -> None:
        """Create delegated_capabilities table if not exists.

        Called once on process startup.
        """
        if not self.pool:
            return

        conn = self.pool.getconn()
        try:
            with conn.cursor() as cur:
                # Create table
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS delegated_capabilities (
                        delegation_id UUID NOT NULL,
                        source_spiffe_id TEXT NOT NULL,
                        delegate_spiffe_id TEXT NOT NULL,
                        capability TEXT NOT NULL,
                        issued_at TIMESTAMP NOT NULL,
                        expires_at TIMESTAMP NOT NULL,
                        revoked_at TIMESTAMP,
                        justification TEXT NOT NULL,
                        policy_source TEXT NOT NULL,
                        PRIMARY KEY (delegation_id, capability)
                    )
                """
                )

                # Create indexes separately
                cur.execute("CREATE INDEX IF NOT EXISTS idx_delegate ON delegated_capabilities (delegate_spiffe_id)")
                cur.execute("CREATE INDEX IF NOT EXISTS idx_source ON delegated_capabilities (source_spiffe_id)")
                cur.execute("CREATE INDEX IF NOT EXISTS idx_expires ON delegated_capabilities (expires_at)")
                cur.execute("CREATE INDEX IF NOT EXISTS idx_revoked ON delegated_capabilities (revoked_at)")

                conn.commit()
                log.info("delegated_capabilities table ready")
        except Exception as e:
            log.error(f"Failed to create delegation schema: {e}")
            conn.rollback()
        finally:
            self.pool.putconn(conn)

    def persist_delegation(self, delegation: DelegatedCapability) -> None:
        """Persist a newly issued delegation.

        One row per capability (denormalized for index efficiency).
        No updates except revoked_at.

        Args:
            delegation: DelegatedCapability instance
        """
        if not self.pool:
            return

        conn = self.pool.getconn()
        try:
            with conn.cursor() as cur:
                for cap in delegation.capabilities:
                    cur.execute(
                        """
                        INSERT INTO delegated_capabilities (
                            delegation_id, source_spiffe_id, delegate_spiffe_id,
                            capability, issued_at, expires_at, revoked_at,
                            justification, policy_source
                        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                        ON CONFLICT (delegation_id, capability) DO NOTHING
                        """,
                        (
                            delegation.delegation_id,
                            delegation.source_spiffe_id,
                            delegation.delegate_spiffe_id,
                            cap,
                            delegation.issued_at,
                            delegation.expires_at,
                            None,
                            delegation.justification,
                            delegation.policy_source,
                        ),
                    )
                conn.commit()
                log.debug(f"Persisted delegation {delegation.delegation_id}")
        except Exception as e:
            log.error(f"Failed to persist delegation {delegation.delegation_id}: {e}")
            conn.rollback()
            raise
        finally:
            self.pool.putconn(conn)

    def mark_revoked(self, delegation_id: str, revoked_at: datetime) -> None:
        """Mark a delegation as revoked (update revoked_at only).

        Args:
            delegation_id: UUID of delegation to revoke
            revoked_at: Timestamp of revocation
        """
        if not self.pool:
            return

        conn = self.pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE delegated_capabilities SET revoked_at = %s WHERE delegation_id = %s",
                    (revoked_at, delegation_id),
                )
                conn.commit()
                log.debug(f"Marked delegation {delegation_id} as revoked")
        except Exception as e:
            log.error(f"Failed to mark delegation as revoked: {e}")
            conn.rollback()
            raise
        finally:
            self.pool.putconn(conn)

    def load_active_delegations(self) -> List[DelegatedCapability]:
        """Load all active delegations on boot (WHERE revoked_at IS NULL AND expires_at > now()).

        Returns:
            List of DelegatedCapability instances
        """
        if not self.pool:
            return []

        delegations = {}  # delegation_id -> DelegatedCapability
        conn = self.pool.getconn()
        try:
            with conn.cursor(cursor_factory=self.psycopg2_extras.DictCursor) as cur:
                cur.execute(
                    """
                    SELECT * FROM delegated_capabilities
                    WHERE revoked_at IS NULL AND expires_at > NOW()
                    ORDER BY delegation_id, capability
                    """
                )
                rows = cur.fetchall()

                for row in rows:
                    did = row["delegation_id"]
                    if did not in delegations:
                        delegations[did] = DelegatedCapability(
                            delegation_id=did,
                            source_spiffe_id=row["source_spiffe_id"],
                            delegate_spiffe_id=row["delegate_spiffe_id"],
                            capabilities=frozenset(),
                            issued_at=row["issued_at"],
                            expires_at=row["expires_at"],
                            justification=row["justification"],
                            policy_source=row["policy_source"],
                            revoked_at=None,
                        )

                    # Add capability to the delegation
                    delegations[did] = DelegatedCapability(
                        delegation_id=delegations[did].delegation_id,
                        source_spiffe_id=delegations[did].source_spiffe_id,
                        delegate_spiffe_id=delegations[did].delegate_spiffe_id,
                        capabilities=delegations[did].capabilities | {row["capability"]},
                        issued_at=delegations[did].issued_at,
                        expires_at=delegations[did].expires_at,
                        justification=delegations[did].justification,
                        policy_source=delegations[did].policy_source,
                        revoked_at=None,
                    )

                log.info(f"Loaded {len(delegations)} active delegations from persistence")
                return list(delegations.values())
        except Exception as e:
            log.error(f"Failed to load delegations from persistence: {e}")
            return []
        finally:
            self.pool.putconn(conn)
