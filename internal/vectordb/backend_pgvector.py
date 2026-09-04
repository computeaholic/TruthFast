"""ThreadForge — pgvector Backend (System-Level)
Authoritative vector store.
Location: core/vectordb/backend_pgvector.py
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

# Integration-only imports: deferred to prevent unit test collection failure
if TYPE_CHECKING:
    pass


class PgVectorBackend:
    def __init__(self) -> None:
        self.conn_str: str | None = None

    def _connection_string(self) -> str:
        conn_str = self.conn_str
        if conn_str is None:
            raise RuntimeError("pgvector connection string not set")
        return conn_str

    # Operator-AI sets this centrally
    def set_connection(self, conn_str: str) -> None:
        self.conn_str = conn_str

    # -------------------------------
    # INSERT
    # -------------------------------
    def insert(self, req: Any) -> dict[str, object]:
        # Integration-only imports: deferred to runtime
        import psycopg
        import psycopg.types.json
        from psycopg.rows import dict_row

        with psycopg.connect(self._connection_string(), row_factory=dict_row) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO embeddings (id, vector, payload, namespace)
                    VALUES (%s, %s, %s, %s)
                    ON CONFLICT (id) DO UPDATE SET
                        vector = EXCLUDED.vector,
                        payload = EXCLUDED.payload,
                        namespace = EXCLUDED.namespace;
                    """,
                    (
                        req.id,
                        req.vector,
                        psycopg.types.json.Json(req.payload),
                        req.namespace,
                    ),
                )
            conn.commit()

        return {"backend": "pgvector", "status": "ok", "id": req.id}

    # -------------------------------
    # SEARCH
    # -------------------------------
    def search(self, req: Any) -> dict[str, object]:
        # Integration-only imports: deferred to runtime
        import psycopg
        from psycopg.rows import dict_row

        with psycopg.connect(self._connection_string(), row_factory=dict_row) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT id, payload,
                           (1 - (vector <=> %s)) AS score
                    FROM embeddings
                    WHERE namespace = %s
                    ORDER BY score DESC
                    LIMIT %s;
                    """,
                    (req.vector, req.namespace, req.top_k),
                )
                rows = cur.fetchall()

        return {"backend": "pgvector", "matches": rows}

    # -------------------------------
    # DELETE
    # -------------------------------
    def delete(self, req: Any) -> dict[str, object]:
        # Integration-only imports: deferred to runtime
        import psycopg
        from psycopg.rows import dict_row

        with psycopg.connect(self._connection_string(), row_factory=dict_row) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    DELETE FROM embeddings
                    WHERE id = %s AND namespace = %s;
                    """,
                    (req.id, req.namespace),
                )
            conn.commit()

        return {"backend": "pgvector", "status": "deleted", "id": req.id}
