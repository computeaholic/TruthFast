# operator/ledger/writers/pg_writer.py

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from runtime.ledger.schemas import LedgerEntry

# Integration-only imports: deferred to prevent unit test collection failure
if TYPE_CHECKING:
    pass


class PostgresLedgerWriter:
    """High-performance Postgres ledger writer with a shared static connection pool.
    Pyright-safe, production-grade, and used by the Operator-AI vector executor.
    """

    # Explicit type so Pyright knows pool is non-null when used
    _pool: Any = None  # psycopg2.pool.SimpleConnectionPool | None

    def __init__(self, dsn: str):
        # Integration-only imports: deferred to runtime
        import psycopg2
        import psycopg2.pool

        self.dsn = dsn

        # Initialize connection pool once per process
        if PostgresLedgerWriter._pool is None:
            PostgresLedgerWriter._pool = psycopg2.pool.SimpleConnectionPool(minconn=1, maxconn=5, dsn=dsn)

    # ---------------------------------------------------------
    # Write Entry
    # ---------------------------------------------------------
    def write(self, entry: LedgerEntry):
        """Insert a ledger entry into PostgreSQL using pooled connections.
        Fully pyright-clean.
        """
        # Integration-only imports: deferred to runtime
        from psycopg2.extras import Json

        pool = PostgresLedgerWriter._pool

        # Ensure pool is initialized at runtime (replaces assert to avoid being stripped in optimized builds)
        if pool is None:
            raise RuntimeError("PostgresLedgerWriter._pool was not initialized")

        conn = None
        try:
            conn = pool.getconn()  # ✔ pyright knows this is valid
            cur = conn.cursor()

            cur.execute(
                """
                INSERT INTO operator_ledger (
                    ts, trace_id, sender, recipient, op,
                    priority, reflex_verdict, truth_verdict,
                    backend, status, payload, result, duration_ms
                )
                VALUES (
                    to_timestamp(%(ts)s),
                    %(trace_id)s,
                    %(sender)s,
                    %(recipient)s,
                    %(op)s,
                    %(priority)s,
                    %(reflex_verdict)s,
                    %(truth_verdict)s,
                    %(backend)s,
                    %(status)s,
                    %(payload)s,
                    %(result)s,
                    %(duration_ms)s
                );
                """,
                {
                    "ts": entry.ts,
                    "trace_id": entry.trace_id,
                    "sender": entry.sender,
                    "recipient": entry.recipient,
                    "op": entry.op,
                    "priority": entry.priority,
                    "reflex_verdict": entry.reflex_verdict,
                    "truth_verdict": entry.truth_verdict,
                    "backend": entry.backend,
                    "status": entry.status,
                    "payload": Json(entry.payload),
                    "result": Json(entry.result),
                    "duration_ms": entry.duration_ms,
                },
            )

            conn.commit()

        finally:
            # Always return connection to pool
            if conn:
                pool.putconn(conn)  # ✔ pyright-clean
