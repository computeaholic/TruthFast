# runtime/vector/indexer/cursor.py
"""Cursor management for Qdrant indexer.
Ensures total ordering and no skipped/duplicated events.
"""

from typing import TYPE_CHECKING, Optional

# Integration-only imports: deferred to prevent unit test collection failure
if TYPE_CHECKING:
    import psycopg

# Cursor may be either a (created_at, event_id) tuple or a single ISO timestamp string
Cursor = Optional[tuple[str, str] | str]  # (created_at, event_id) or ISO timestamp string


def load_cursor(conn: "psycopg.Connection", source: str) -> Cursor:
    """Load the last processed cursor for the given source."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT created_at::text, event_id::text
            FROM vector_ingest_cursors
            WHERE source = %s
        """,
            (source,),
        )
        row = cur.fetchone()
        return (row[0], row[1]) if row else None


def save_cursor(conn: "psycopg.Connection", source: str, created_at: str, event_id: str):
    """Save the cursor for the given source. Idempotent operation."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO vector_ingest_cursors (source, created_at, event_id)
            VALUES (%s, %s, %s)
            ON CONFLICT (source)
            DO UPDATE SET created_at = EXCLUDED.created_at,
                          event_id = EXCLUDED.event_id
        """,
            (source, created_at, event_id),
        )


def create_cursor_table(conn: "psycopg.Connection"):
    """Create the vector_ingest_cursors table if it doesn't exist."""
    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS vector_ingest_cursors (
                source TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                event_id TEXT NOT NULL,
                updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
            )
        """,
        )
    conn.commit()
