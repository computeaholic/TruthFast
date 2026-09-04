# Path: runtime/ledger/postgres_writer.py

from __future__ import annotations

import uuid
from typing import TYPE_CHECKING, Any

from api.core.identity_config import TRUST_DOMAIN
from runtime.ledger.schemas import LedgerEntry

# Integration-only imports: deferred to prevent unit test collection failure
if TYPE_CHECKING:
    pass


class PostgresLedgerWriter:
    """High-performance Postgres ledger writer with a shared static connection pool.
    Used by the runtime Operator-AI ledger.

    On init this writer performs a hard schema check to ensure required
    columns and triggers are present; missing schema elements result in a
    RuntimeError to prevent accidental writes into an unhashed or unverified
    ledger.
    """

    _pool: Any = None  # psycopg2.pool.SimpleConnectionPool | None

    def __init__(self, dsn: str):
        # Integration-only imports: deferred to runtime
        simple_pool_cls: Any | None = None
        try:
            from psycopg2.pool import SimpleConnectionPool  # type: ignore[import-not-found]

            simple_pool_cls = SimpleConnectionPool
        except Exception as e:  # pragma: no cover - optional dependency import
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                "psycopg2 SimpleConnectionPool import", e
            )  # nosec B110: Optional dependency import failure is tolerated in test environments

        from runtime.authority.signing import load_authority_private_key

        self.dsn = dsn

        if PostgresLedgerWriter._pool is None:
            if simple_pool_cls is not None:
                PostgresLedgerWriter._pool = simple_pool_cls(
                    minconn=1,
                    maxconn=10,  # Increased from 5 for runtime node performance
                    dsn=dsn,
                )
            else:
                # Try to import psycopg at runtime; fail with a clear message if unavailable
                try:
                    import psycopg as _psycopg  # type: ignore[import-not-found]
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional("psycopg import", e)  # nosec B110: Optional dependency import failure
                    raise RuntimeError(
                        "Postgres support not installed. Install 'psycopg' or 'psycopg2' to use PostgresLedgerWriter."
                    ) from None

                # Minimal pool wrapper using psycopg.connect. We avoid requiring
                # the optional psycopg_pool package here to keep runtime simple and
                # deterministic for tests.
                class _SimplePool:
                    def __init__(self, dsn: str):
                        self._dsn = dsn

                    def getconn(self):
                        return _psycopg.connect(self._dsn)

                    def putconn(self, conn):
                        try:
                            conn.close()
                        except Exception as e:
                            from runtime.util.best_effort import swallow_optional

                            swallow_optional("connection close", e)  # nosec B110: best-effort cleanup should not raise

        try:
            self._authority_private_key = load_authority_private_key()
        except Exception as e:
            # Fail fast if key loading fails catastrophically
            raise RuntimeError(f"Failed to load authority private key: {e}") from e

        # Perform strict schema assertions; abort if expectations not met
        assert PostgresLedgerWriter._pool is not None, "Connection pool not initialized"
        conn = None
        try:
            conn = PostgresLedgerWriter._pool.getconn()
            cur = conn.cursor()
            cur.execute("SELECT column_name FROM information_schema.columns WHERE table_name='operator_ledger_v2'")
            cols = {r[0] for r in cur.fetchall()}
            required = {
                "prev_seal",
                "seal",
                "is_demo",
                "spiffe_id",
                "identity_attested",
                "identity_hash",
                "authority_signature",
            }
            missing = required - cols
            if missing:
                raise RuntimeError(f"operator_ledger_v2 missing required columns: {sorted(missing)}")

            # Check trigger exists
            cur.execute("SELECT tgname FROM pg_trigger WHERE tgname='operator_ledger_verify_insert_trg'")
            if cur.fetchone() is None:
                raise RuntimeError("operator_ledger_verify_insert_trg trigger not found on operator_ledger_v2")

            # Check public view exists and basic definition
            cur.execute(
                "SELECT table_name, view_definition "
                "FROM information_schema.views "
                "WHERE table_name='operator_ledger_v2_public'",
            )
            row = cur.fetchone()
            if row is None:
                raise RuntimeError(
                    "operator_ledger_v2_public view not found; please apply migrations/0003_create_public_view.sql"
                )
            # Basic content check: ensure is_demo filtering exists and references base table
            _, view_def = row
            if "is_demo" not in view_def.lower() or "operator_ledger_v2" not in view_def.lower():
                raise RuntimeError("operator_ledger_v2_public view malformed or missing is_demo filter")
        finally:
            if conn is not None:
                assert PostgresLedgerWriter._pool is not None
                PostgresLedgerWriter._pool.putconn(conn)

    # ------------------------------------------------------------------
    def write(self, entry: LedgerEntry) -> None:
        """Insert a ledger entry into PostgreSQL using pooled connections."""
        # Integration-only imports: deferred to runtime
        from psycopg2.extras import Json

        spiffe_id = f"spiffe://{TRUST_DOMAIN}/unattributed"
        identity_class = "unclassified"

        if entry.ppit:
            spiffe_id = entry.ppit.get("spiffe_id") or spiffe_id
            identity_class = entry.ppit.get("identity_class") or identity_class

        pool = PostgresLedgerWriter._pool
        if pool is None:
            raise RuntimeError("PostgresLedgerWriter._pool was not initialized")

        conn = None
        try:
            conn = pool.getconn()
            cur = conn.cursor()

            # Prepare authority metadata
            identity_attested = bool(entry.identity.attested) if entry.identity else False
            authority_signature = None
            # Log path for test observability
            import logging as _logging

            logger = _logging.getLogger(__name__)
            logger.debug(
                "PostgresLedgerWriter.write: identity_attested=%s, identity_hash=%s",
                identity_attested,
                entry.identity_hash,
            )
            if identity_attested and entry.identity_hash and entry.seal:
                if self._authority_private_key is None:
                    raise RuntimeError("Attempting to write authoritative row but authority private key not available")
                from runtime.authority.signing import sign_authority_material

                authority_signature = sign_authority_material(
                    self._authority_private_key, entry.seal, entry.identity_hash
                )
                logger.debug("PostgresLedgerWriter.write: authority_signature computed")

            cur.execute(
                """
                INSERT INTO operator_ledger_v2 (
                    id, ts, trace_id, sender, recipient, op,
                    priority, reflex_verdict, truth_verdict,
                    backend, status, payload, result, duration_ms,
                    envelope_id, prev_seal, seal, ppit, spiffe_id,
                    identity_class, identity_attested, authority_signature,
                )
                VALUES (
                    %(id)s, to_timestamp(%(ts)s),
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
                    %(duration_ms)s,
                    %(envelope_id)s,
                    %(prev_seal)s,
                    %(seal)s,
                    %(ppit)s,
                    %(spiffe_id)s,
                    %(identity_class)s,
                    %(identity_attested)s,
                    %(authority_signature)s
                );
                """,
                {
                    "id": str(uuid.uuid4()),
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
                    "envelope_id": entry.envelope_id,
                    "prev_seal": entry.prev_seal,
                    "seal": entry.seal,
                    "ppit": Json(entry.ppit) if entry.ppit else None,
                    "spiffe_id": spiffe_id,
                    "identity_class": identity_class,
                    "identity_attested": identity_attested,
                    "authority_signature": authority_signature,
                },
            )

            conn.commit()
        finally:
            if conn is not None:
                pool.putconn(conn)

    # ------------------------------------------------------------------
    def write_many(self, entries: list[LedgerEntry]) -> None:
        """Batch insert multiple ledger entries into PostgreSQL using a single transaction.
        Preserves append-only guarantees and identity completeness.
        """
        if not entries:
            return

        # Integration-only imports: deferred to runtime
        from psycopg2.extras import Json

        pool = PostgresLedgerWriter._pool
        if pool is None:
            raise RuntimeError("PostgresLedgerWriter._pool was not initialized")

        conn = None
        try:
            conn = pool.getconn()
            cur = conn.cursor()

            # Prepare batch data
            values = []
            for entry in entries:
                spiffe_id = f"spiffe://{TRUST_DOMAIN}/unattributed"
                identity_class = "unclassified"

                if entry.ppit:
                    spiffe_id = entry.ppit.get("spiffe_id") or spiffe_id
                    identity_class = entry.ppit.get("identity_class") or identity_class

                identity_attested = bool(entry.identity.attested) if entry.identity else False
                authority_signature = None
                if identity_attested and entry.identity_hash and entry.seal:
                    if self._authority_private_key is None:
                        raise RuntimeError("authority private key not available")
                    from runtime.authority.signing import sign_authority_material

                    authority_signature = sign_authority_material(
                        self._authority_private_key,
                        entry.seal,
                        entry.identity_hash,
                    )

                values.append(
                    (
                        str(uuid.uuid4()),
                        entry.ts,
                        entry.trace_id,
                        entry.sender,
                        entry.recipient,
                        entry.op,
                        entry.priority,
                        entry.reflex_verdict,
                        entry.truth_verdict,
                        entry.backend,
                        entry.status,
                        Json(entry.payload),
                        Json(entry.result),
                        entry.duration_ms,
                        entry.envelope_id,
                        entry.prev_seal,
                        entry.seal,
                        Json(entry.ppit) if entry.ppit else None,
                        spiffe_id,
                        identity_class,
                        entry.identity_hash,
                        identity_attested,
                        authority_signature,
                    ),
                )

            # Execute batch insert
            cur.executemany(
                """
                INSERT INTO operator_ledger_v2 (
                    id, ts, trace_id, sender, recipient, op,
                    priority, reflex_verdict, truth_verdict,
                    backend, status, payload, result, duration_ms,
                    envelope_id, prev_seal, seal, ppit, spiffe_id,
                    identity_class, identity_hash, identity_attested,
                    authority_signature,
                )
                VALUES (
                    %s, to_timestamp(%s),
                    %s, %s, %s, %s,
                    %s, %s, %s,
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                );
                """,
                values,
            )

            conn.commit()
        finally:
            if conn is not None:
                pool.putconn(conn)

    def get_last_seal(self) -> str:
        """Return the most recent seal stored in the operator ledger, or GENESIS if none."""
        pool = PostgresLedgerWriter._pool
        if pool is None:
            raise RuntimeError("PostgresLedgerWriter._pool was not initialized")

        conn = None
        try:
            conn = pool.getconn()
            cur = conn.cursor()
            # Use the public view (non-demo) when deriving last seal for authoritative sealing
            cur.execute("SELECT seal FROM operator_ledger_v2_public ORDER BY ts DESC LIMIT 1;")
            row = cur.fetchone()
            return row[0] if row and row[0] else "GENESIS"
        finally:
            if conn is not None:
                pool.putconn(conn)

    # ------------------------------------------------------------------
    def fetch_decision_record(self, decision_id: str | None = None, provenance_hash: str | None = None) -> dict | None:
        """Fetch a decision_record_commit ledger row from Postgres by decision_id or provenance_hash.

        Returns dict with keys: payload (dict), ts (float epoch seconds) or None if not found.
        """
        if not decision_id and not provenance_hash:
            raise ValueError("fetch_decision_record requires decision_id or provenance_hash")

        pool = PostgresLedgerWriter._pool
        if pool is None:
            raise RuntimeError("PostgresLedgerWriter._pool was not initialized")

        conn = None
        try:
            conn = pool.getconn()
            cur = conn.cursor()

            if decision_id:
                cur.execute(
                    """
                    SELECT payload::text, extract(epoch from ts) as ts_epoch
                    FROM operator_ledger_v2
                    WHERE op = 'decision_record_commit' AND payload->> 'decision_id' = %s
                    ORDER BY ts DESC LIMIT 1
                    """,
                    (str(decision_id),),
                )
            else:
                cur.execute(
                    """
                    SELECT payload::text, extract(epoch from ts) as ts_epoch
                    FROM operator_ledger_v2
                    WHERE op = 'decision_record_commit' AND payload->> 'provenance_hash' = %s
                    ORDER BY ts DESC LIMIT 1
                    """,
                    (str(provenance_hash),),
                )

            row = cur.fetchone()
            if not row:
                return None
            import json as _json

            payload_text, ts_epoch = row
            payload = _json.loads(payload_text)

            # Verify decision payload signature (fail-closed)
            try:
                from runtime.civ.provenance.artifact_signing import SignatureVerifier, SigningError

                verifier = SignatureVerifier()
                verified, verr = verifier.verify_decision_payload_signature(payload)
                if not verified:
                    # Emit metrics for signature verification failure
                    try:
                        from runtime.telemetry.prometheus_exporter import observe_decision_signature_failure

                        observe_decision_signature_failure(reason=str(verr or "invalid_signature"))
                    except Exception as e:
                        from runtime.util.best_effort import swallow_optional

                        swallow_optional(
                            "observe_decision_signature_failure (signature verification)", e
                        )  # nosec B110: Metrics are best-effort; failures must not mask signature verification
                    raise SigningError(f"DecisionRecord signature verification failed: {verr}")
            except Exception as e:
                # On any verification error, emit metrics and fail-closed
                try:
                    from runtime.telemetry.prometheus_exporter import observe_decision_signature_failure

                    observe_decision_signature_failure(reason=str(e))
                except Exception as e2:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "observe_decision_signature_failure (verification error)", e2
                    )  # nosec B110: Metrics are best-effort; failures must not mask verification errors
                raise RuntimeError(f"DecisionRecord signature verification error: {e}") from e

            return {"payload": payload, "ts": float(ts_epoch)}
        finally:
            if conn is not None:
                PostgresLedgerWriter._pool.putconn(conn)

    # ------------------------------------------------------------------
    def fetch_operator_override(self, decision_id: str) -> dict | None:
        """Fetch recent governance intent/override that references the decision_id, if any."""
        pool = PostgresLedgerWriter._pool
        if pool is None:
            raise RuntimeError("PostgresLedgerWriter._pool was not initialized")

        conn = None
        try:
            conn = pool.getconn()
            cur = conn.cursor()
            cur.execute(
                """
                SELECT payload::text, extract(epoch from ts) as ts_epoch
                FROM operator_ledger_v2
                WHERE op IN ('governance_intent', 'operator_override')
                  AND (
                    payload->> 'governance_action_id' = %s
                    OR payload->> 'decision_id' = %s
                  )
                ORDER BY ts DESC LIMIT 1
                """,
                (str(decision_id), str(decision_id)),
            )
            row = cur.fetchone()
            if not row:
                return None
            import json as _json

            payload_text, ts_epoch = row
            payload = _json.loads(payload_text)
            return {"payload": payload, "ts": float(ts_epoch)}
        finally:
            if conn is not None:
                PostgresLedgerWriter._pool.putconn(conn)

    # ------------------------------------------------------------------
    def fetch_admission(self, decision_id: str | None = None, provenance_hash: str | None = None) -> dict | None:
        """Fetch the operator admission entry for a DecisionRecord, if any."""
        pool = PostgresLedgerWriter._pool
        if pool is None:
            raise RuntimeError("PostgresLedgerWriter._pool was not initialized")

        conn = None
        try:
            conn = pool.getconn()
            cur = conn.cursor()
            if decision_id:
                cur.execute(
                    """
                    SELECT payload::text, extract(epoch from ts) as ts_epoch
                    FROM operator_ledger_v2
                    WHERE op = 'decision_admission' AND payload->> 'decision_id' = %s
                    ORDER BY ts DESC LIMIT 1
                    """,
                    (str(decision_id),),
                )
            else:
                cur.execute(
                    """
                    SELECT payload::text, extract(epoch from ts) as ts_epoch
                    FROM operator_ledger_v2
                    WHERE op = 'decision_admission' AND payload->> 'decision_provenance_hash' = %s
                    ORDER BY ts DESC LIMIT 1
                    """,
                    (str(provenance_hash),),
                )

            row = cur.fetchone()
            if not row:
                return None
            import json as _json

            payload_text, ts_epoch = row
            payload = _json.loads(payload_text)
            return {"payload": payload, "ts": float(ts_epoch)}
        finally:
            if conn is not None:
                PostgresLedgerWriter._pool.putconn(conn)
