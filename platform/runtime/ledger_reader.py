"""Canonical Ledger Reader
-----------------------
Read-only access layer for ThreadForge ledgers.
Uses threadforge_reader credentials ONLY.

Hard guarantees:
- SELECT-only
- Explicit column lists (no SELECT *)
- Deterministic ordering
- Bounded result sets
- No joins
- No writes
- No side effects

This module is safe to import into:
- APIs
- Interpreters
- Auditors
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime
from typing import TYPE_CHECKING, Any

# Integration-only imports: deferred to prevent unit test collection failure
if TYPE_CHECKING:
    pass

# ----------------------------
# Connection handling
# ----------------------------


def _get_reader_conn():
    """Create a read-only database connection using reader credentials.
    Autocommit is enabled to avoid transaction state leakage.
    """
    # Integration-only imports: deferred to runtime
    import psycopg2
    from psycopg2.extras import RealDictCursor

    conn = psycopg2.connect(
        host=os.environ["THREADFORGE_READER_DB_HOST"],
        port=os.environ.get("THREADFORGE_READER_DB_PORT", "5432"),
        dbname=os.environ["THREADFORGE_READER_DB_NAME"],
        user=os.environ["THREADFORGE_READER_DB_USER"],
        password=os.environ["THREADFORGE_READER_DB_PASSWORD"],
        cursor_factory=RealDictCursor,
    )
    conn.set_session(readonly=True, autocommit=True)
    return conn


# ----------------------------
# Operator Ledger Reads
# ----------------------------


def fetch_operator_events(
    *,
    limit: int = 100,
    after_event_id: uuid.UUID | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
) -> list[dict]:
    """Fetch operator ledger events.

    Ordering:
        created_at ASC, id ASC (deterministic)

    Cursor:
        after_event_id (exclusive)

    Time bounds:
        since <= created_at < until
    """
    if limit <= 0 or limit > 1000:
        raise ValueError("limit must be between 1 and 1000")

    base_query = """
        SELECT
            id,
            created_at,
            operator_id,
            action_type,
            action_target,
            action_payload,
            policy_id,
            policy_outcome,
            request_id
        FROM operator_ledger
        WHERE 1=1
    """

    params: dict[str, Any] = {}

    if after_event_id is not None:
        base_query += " AND id > %(after_event_id)s"
        params["after_event_id"] = str(after_event_id)

    if since is not None:
        base_query += " AND created_at >= %(since)s"
        params["since"] = since

    if until is not None:
        base_query += " AND created_at < %(until)s"
        params["until"] = until

    base_query += """
        ORDER BY created_at ASC, id ASC
        LIMIT %(limit)s
    """
    params["limit"] = limit

    with _get_reader_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(base_query, params)
            return list(cur.fetchall())


# ----------------------------
# Value Ledger Reads
# ----------------------------


def fetch_value_events(
    *,
    limit: int = 100,
    after_event_id: uuid.UUID | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
    identity_class: str | None = None,
) -> list[dict]:
    """Fetch value ledger (economic truth) events.

    identity_class must be one of:
        native | translated | bridged | ephemeral
    """
    if limit <= 0 or limit > 1000:
        raise ValueError("limit must be between 1 and 1000")

    if identity_class is not None:
        if identity_class not in {"native", "translated", "bridged", "ephemeral"}:
            raise ValueError(f"Invalid identity_class: {identity_class}")

    base_query = """
        SELECT
            id,
            created_at,
            identity_id,
            identity_class,
            provenance_type,
            provenance_hash,
            economic_action,
            economic_value,
            currency,
            policy_id,
            policy_outcome,
            request_id
        FROM value_ledger
        WHERE 1=1
    """

    params: dict[str, Any] = {}

    if after_event_id is not None:
        base_query += " AND id > %(after_event_id)s"
        params["after_event_id"] = str(after_event_id)

    if since is not None:
        base_query += " AND created_at >= %(since)s"
        params["since"] = since

    if until is not None:
        base_query += " AND created_at < %(until)s"
        params["until"] = until

    if identity_class is not None:
        base_query += " AND identity_class = %(identity_class)s"
        params["identity_class"] = identity_class

    base_query += """
        ORDER BY created_at ASC, id ASC
        LIMIT %(limit)s
    """
    params["limit"] = limit

    with _get_reader_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(base_query, params)
            return list(cur.fetchall())
