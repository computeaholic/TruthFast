"""Block 1A.10: Controlled Append-Only Write Path

Runtime ingestion module for ThreadForge ledgers.
Write-only, no reads, no retries, no upserts.

Capabilities:
- insert_operator_event(payload): Insert into operator_ledger
- insert_value_event(payload): Insert into value_ledger

Error handling:
- success: Insert succeeded
- duplicate: Primary key violation (treated as success)
- transient_failure: Temporary connectivity issues
- permanent_failure: Schema/permission issues
"""

import os
import uuid
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

# Integration-only imports: deferred to prevent unit test collection failure
if TYPE_CHECKING:
    from psycopg2 import sql


@dataclass
class WriteResult:
    """Result of a ledger write operation."""

    success: bool
    error_type: str | None = None
    error_message: str | None = None


class LedgerWriter:
    """Append-only ledger writer for Block 1A.10.

    Connects using threadforge_writer role with minimal privileges.
    """

    def __init__(self):
        # Get credentials from environment (injected by Helm)
        db_host = os.environ.get("THREADFORGE_DB_HOST", "postgres.threadforge-system.svc.cluster.local")
        db_port = os.environ.get("THREADFORGE_DB_PORT", "5432")
        db_name = os.environ.get("THREADFORGE_DB_NAME", "threadforge")
        db_user = os.environ.get("THREADFORGE_DB_USER", "threadforge_writer")
        db_password = os.environ.get("THREADFORGE_DB_PASSWORD")

        if not db_password:
            raise ValueError("THREADFORGE_DB_PASSWORD environment variable required")

        self.dsn = f"host={db_host} port={db_port} dbname={db_name} user={db_user} password={db_password}"

    def insert_operator_event(self, payload: dict[str, Any]) -> WriteResult:
        """Insert a single operator event into operator_ledger.

        Payload must contain all required fields except id (auto-generated if missing).
        """
        # Integration-only imports: deferred to runtime
        from psycopg2.extras import Json

        # Ensure we have an ID
        event_id = payload.get("id", str(uuid.uuid4()))

        # Build the insert query
        query = sql.SQL(
            """
            INSERT INTO operator_ledger (
                id, timestamp_utc, operator_id, operator_role, action_type,
                action_scope, intent, justification, target_type, target_identifier,
                result, result_detail, metadata, spiffe_id, identity_class, created_at
            ) VALUES (
                %(id)s, %(timestamp_utc)s, %(operator_id)s, %(operator_role)s, %(action_type)s,
                %(action_scope)s, %(intent)s, %(justification)s, %(target_type)s, %(target_identifier)s,
                %(result)s, %(result_detail)s, %(metadata)s, %(spiffe_id)s, %(identity_class)s, now()
            )
        """,
        )

        params = {
            "id": event_id,
            "timestamp_utc": payload["timestamp_utc"],
            "operator_id": payload["operator_id"],
            "operator_role": payload["operator_role"],
            "action_type": payload["action_type"],
            "action_scope": payload["action_scope"],
            "intent": payload["intent"],
            "justification": payload.get("justification"),
            "target_type": payload.get("target_type"),
            "target_identifier": payload.get("target_identifier"),
            "result": payload["result"],
            "result_detail": payload.get("result_detail"),
            "metadata": Json(payload.get("metadata")) if payload.get("metadata") else None,
            "spiffe_id": payload.get("spiffe_id", payload["operator_id"]),  # Default to operator_id
            "identity_class": payload.get("identity_class", payload["operator_role"]),  # Default to operator_role
        }

        return self._execute_insert(query, params)

    def insert_value_event(self, payload: dict[str, Any]) -> WriteResult:
        """Insert a single value event into value_ledger.

        Payload must contain all required fields except id (auto-generated if missing).
        """
        # Integration-only imports: deferred to runtime
        from psycopg2 import sql

        # Ensure we have an ID
        event_id = payload.get("id", str(uuid.uuid4()))

        # Build the insert query
        query = sql.SQL(
            """
            INSERT INTO value_ledger (
                id, identity_class, subject_identity, provenance_type, provenance_hash,
                value_domain, value_type, value_amount, value_unit, policy_id,
                policy_outcome, spiffe_id, recorded_at, notes
            ) VALUES (
                %(id)s, %(identity_class)s, %(subject_identity)s, %(provenance_type)s, %(provenance_hash)s,
                %(value_domain)s, %(value_type)s, %(value_amount)s, %(value_unit)s, %(policy_id)s,
                %(policy_outcome)s, %(spiffe_id)s, now(), %(notes)s
            )
        """,
        )

        params = {
            "id": event_id,
            "identity_class": payload["identity_class"],
            "subject_identity": payload["subject_identity"],
            "provenance_type": payload["provenance_type"],
            "provenance_hash": payload["provenance_hash"],
            "value_domain": payload["value_domain"],
            "value_type": payload["value_type"],
            "value_amount": payload["value_amount"],
            "value_unit": payload["value_unit"],
            "policy_id": payload.get("policy_id"),
            "policy_outcome": payload["policy_outcome"],
            "spiffe_id": payload.get("spiffe_id", payload["subject_identity"]),  # Default to subject_identity
            "notes": payload.get("notes"),
        }

        return self._execute_insert(query, params)

    def _execute_insert(self, query: "sql.SQL", params: dict[str, Any]) -> WriteResult:
        """Execute a single INSERT operation.

        No retries, no upserts, no selects.
        """
        # Integration-only imports: deferred to runtime
        import psycopg2

        conn = None
        try:
            conn = psycopg2.connect(self.dsn)
            cur = conn.cursor()

            cur.execute(query, params)
            conn.commit()

            return WriteResult(success=True)

        except psycopg2.IntegrityError as e:
            # Primary key violation - treat as logical success
            if conn:
                conn.rollback()
            return WriteResult(success=True, error_type="duplicate", error_message=str(e))

        except psycopg2.OperationalError as e:
            # Connection/transient issues
            if conn:
                conn.rollback()
            return WriteResult(success=False, error_type="transient_failure", error_message=str(e))

        except (psycopg2.ProgrammingError, psycopg2.DataError) as e:
            # Schema/permission/permanent issues
            if conn:
                conn.rollback()
            return WriteResult(success=False, error_type="permanent_failure", error_message=str(e))

        except Exception as e:
            # Any other error
            if conn:
                conn.rollback()
            return WriteResult(success=False, error_type="permanent_failure", error_message=str(e))

        finally:
            if conn:
                conn.close()
