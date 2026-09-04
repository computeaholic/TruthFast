# runtime/vector/indexer/extract.py
"""Read-only extraction from authoritative sources.

Explicit allow-list of fields to embed, no secrets or raw payloads.
"""

from typing import TYPE_CHECKING, Any, Mapping, Optional

# Boundary-typing: DB drivers, cursors and external clients are intentionally
# typed as permissive aliases at this module boundary. This keeps runtime code
# checked while avoiding brittle, deep typing of DB cursor internals.
# Integration-only imports: deferred to prevent unit test collection failure

try:
    from clickhouse_driver import Client  # type: ignore[import-not-found]
except Exception:  # pragma: no cover - optional integration
    Client = None

from runtime.vector.indexer.config import IndexerConfig

# Boundary aliases (intentionally permissive)
CursorLike = Any
RowMapping = Mapping[str, Any]
PsycopgConnection = Any
ClientType = Any

if TYPE_CHECKING:
    # Narrower types when available for static checks only
    from psycopg import Connection as PsycopgConnection  # type: ignore[import-not-found]


def extract_operator_ledger(conn: "PsycopgConnection", cursor: CursorLike, limit: int) -> list[RowMapping]:
    """Extract from operator_ledger_v2 (Postgres).

    Only embed explicit allow-listed fields.
    """
    sql = """
        SELECT
            id,
            ts,
            spiffe_id,
            identity_class,
            -- Explicit allow-list only
            json_build_object(
                'action_type', action_type,
                'action_scope', action_scope,
                'intent', intent,
                'target_type', target_type,
                'target_identifier', target_identifier,
                'result', result,
                'status', status
            )::text as embed_payload
        FROM operator_ledger_v2
        WHERE %s
           OR (
                ts > %s::timestamptz
                OR (ts = %s::timestamptz AND id > %s::uuid)
              )
        ORDER BY ts ASC, id ASC
        LIMIT %s
    """

    with conn.cursor() as cur:
        # Support both tuple cursors and single-timestamp cursor strings
        cursor_created_at: str | None
        cursor_event_id: str | None
        if isinstance(cursor, str):
            cursor_created_at = cursor
            cursor_event_id = None
        else:
            cursor_created_at = cursor[0] if cursor else None
            cursor_event_id = cursor[1] if cursor else None

        cur.execute(
            sql,
            (
                cursor is None,
                cursor_created_at,
                cursor_created_at,
                cursor_event_id,
                limit,
            ),
        )

        rows: list[RowMapping] = [
            {
                "event_id": str(r[0]),
                "created_at": r[1].isoformat() if hasattr(r[1], "isoformat") else str(r[1]),
                "spiffe_id": r[2],
                "identity_class": r[3],
                "embed_text": r[4],  # JSON string for embedding
                "source": "operator",
            }
            for r in cur.fetchall()
        ]

        # Validate identity_class values against the canonical set enforced by DB schema
        ALLOWED_IDENTITY_CLASSES = {"native", "translated", "bridged", "ephemeral"}
        for row in rows:
            if row["identity_class"] not in ALLOWED_IDENTITY_CLASSES:
                raise ValueError(f"invalid identity_class: {row['identity_class']}")

        return rows


def extract_value_plane_costs(ch: Optional["ClientType"], cursor: CursorLike, limit: int) -> list[RowMapping]:
    if Client is None:
        raise RuntimeError("ClickHouse integration not available; install 'clickhouse-driver'")
    """Extract from value_plane.cost_model (ClickHouse).

    Only embed explicit allow-listed fields.
    """
    sql = """
        SELECT
            event_id,
            created_at,
            spiffe_id,
            identity_class,
            -- Explicit allow-list only
            concat(
                'cost_analysis:',
                toString(compute_units), ',',
                toString(policy_units), ',',
                toString(total_cost_units), ',',
                source_ledger
            ) as embed_text
        FROM value_plane.cost_model
        WHERE (created_at, event_id) > (%s, %s)
        ORDER BY created_at ASC, event_id ASC
        LIMIT %s
    """

    # Handle cursor for ClickHouse (accept tuple or single-timestamp cursor string)
    if isinstance(cursor, str):
        cursor_created_at = cursor
        cursor_event_id = ""
    else:
        cursor_created_at = cursor[0] if cursor else "1970-01-01 00:00:00"
        cursor_event_id = cursor[1] if cursor else ""

    result: Any = ch.execute(sql, (cursor_created_at, cursor_event_id, limit)) if ch is not None else []

    rows: list[RowMapping] = [
        {
            "event_id": str(r[0]),
            "created_at": r[1].isoformat() if hasattr(r[1], "isoformat") else str(r[1]),
            "spiffe_id": r[2],
            "identity_class": r[3],
            "embed_text": r[4],
            "source": "value",
        }
        for r in (result or [])
    ]

    return rows


def extract_batch(
    cfg: IndexerConfig, pg_conn: "PsycopgConnection", ch: Optional["ClientType"], cursor: CursorLike
) -> list[RowMapping]:
    """Extract a batch of records for vectorization."""
    if cfg.source == "operator":
        return extract_operator_ledger(pg_conn, cursor, cfg.batch_size)
    if cfg.source == "value":
        return extract_value_plane_costs(ch, cursor, cfg.batch_size)

    msg = f"Unknown source: {cfg.source}"
    raise ValueError(msg)
