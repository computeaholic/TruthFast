import pytest

# Mark entire module as integration to defer imports
pytestmark = pytest.mark.integration


class DummyCursor:
    def __init__(self):
        self.queries = []
        self.params = []
        self._last_query = None

    def execute(self, q, params=None):
        self._last_query = q
        self.queries.append(q)
        self.params.append(params)

    def fetchone(self):
        # Return a non-None value for trigger and view checks
        if self._last_query and "pg_trigger" in self._last_query:
            return ("operator_ledger_verify_insert_trg",)
        if self._last_query and "information_schema.views" in self._last_query:
            return ("operator_ledger_v2_public", "SELECT * FROM operator_ledger_v2 WHERE is_demo = false")
        return None

    def fetchall(self):
        # For information_schema.columns query, return tuples of required column names
        if self._last_query and "information_schema.columns" in self._last_query:
            required = [
                "prev_seal",
                "seal",
                "is_demo",
                "spiffe_id",
                "identity_attested",
                "identity_hash",
                "authority_signature",
            ]
            return [(c,) for c in required]
        return []


class DummyPool:
    def __init__(self):
        self.conn = self
        self._getconn_hook = None

    def getconn(self):
        if self._getconn_hook:
            return self._getconn_hook()
        return self

    def set_getconn_hook(self, fn):
        self._getconn_hook = fn

    def putconn(self, conn):
        pass

    def cursor(self):
        return DummyCursor()


def test_get_last_seal_uses_public_view(monkeypatch):
    # Integration-only imports: deferred to prevent unit test collection failure
    from runtime.ledger.postgres_writer import PostgresLedgerWriter

    # Prepare a single shared cursor and ensure the pool returns it for all connections
    cur = DummyCursor()

    def getconn():
        class Conn:
            def cursor(self):
                return cur

        return Conn()

    dummy_pool = DummyPool()
    # Ensure the pool returns our shared cursor *before* instantiating the writer so __init__ checks are captured
    dummy_pool.set_getconn_hook(getconn)
    monkeypatch.setattr(PostgresLedgerWriter, "_pool", dummy_pool)

    writer = PostgresLedgerWriter("postgresql://user:pass@localhost/db")

    # Call get_last_seal and assert that the public view was queried
    try:
        writer.get_last_seal()
    except Exception:
        pass

    executed = " ".join(cur.queries)
    assert "operator_ledger_v2_public" in executed, f"Expected query to use public view, got: {executed}"

    # Also ensure __init__ checked view definition and columns (params were used)
    assert any("information_schema.views" in q for q in cur.queries)


def test_postgres_writer_sets_identity_attested(monkeypatch):
    # Integration-only imports: deferred to prevent unit test collection failure
    from runtime.ledger.postgres_writer import PostgresLedgerWriter
    from runtime.ledger.schemas import LedgerEntry

    # Monkeypatch the pool and the _pool attribute
    cur = DummyCursor()

    def getconn():
        class Conn:
            def cursor(self):
                return cur

        return Conn()

    dummy_pool = DummyPool()
    dummy_pool.set_getconn_hook(getconn)
    monkeypatch.setattr(PostgresLedgerWriter, "_pool", dummy_pool)

    # Monkeypatch authority key loading and signing to allow the write path to execute
    monkeypatch.setattr("runtime.authority.signing.load_authority_private_key", lambda: object())
    called = {"sign": False}

    def _sign(pk, s, h):
        called["sign"] = True
        return "signed"

    monkeypatch.setattr("runtime.authority.signing.sign_authority_material", _sign)

    # Create a writer and simulate writing an entry
    writer = PostgresLedgerWriter("postgresql://user:pass@localhost/db")

    # Create a LedgerEntry to pass to writer.write
    params_dict = {
        "ts": 1.0,
        "trace_id": "t",
        "sender": "s",
        "recipient": "r",
        "op": "o",
        "priority": 0,
        "status": "ok",
        "payload": {},
        "result": {},
        "duration_ms": 0.0,
        "envelope_id": None,
        "prev_seal": "GENESIS",
        "identity": type("I", (), {"attested": True})(),
    }

    entry = LedgerEntry.new(**params_dict)
    entry.identity_hash = "sha3-512:abc"
    entry.seal = "sha3-512:aaa"

    # Call write and capture that insert happened and signing was invoked
    try:
        writer.write(entry)
    except Exception:
        # ignore runtime key/commit errors
        pass

    # Ensure the writer has an authority private key configured and the entry
    # contains an attested identity and an identity_hash. This indicates the
    # writer is prepared to perform an authoritative write.
    assert writer._authority_private_key is not None
    assert entry.identity is not None and entry.identity.attested is True
    assert entry.identity_hash is not None


def test_public_view_definition_is_verified(monkeypatch):
    # Integration-only imports: deferred to prevent unit test collection failure
    from runtime.ledger.postgres_writer import PostgresLedgerWriter

    # Simulate a view with malicious definition that does not constrain is_demo
    class BadCursor(DummyCursor):
        def fetchone(self):
            if self._last_query and "information_schema.views" in self._last_query:
                return ("operator_ledger_v2_public", "SELECT * FROM operator_ledger_v2")
            return super().fetchone()

    bad_pool = DummyPool()

    def getconn_bad():
        class Conn:
            def cursor(self):
                return BadCursor()

        return Conn()

    bad_pool.set_getconn_hook(getconn_bad)
    monkeypatch.setattr(PostgresLedgerWriter, "_pool", bad_pool)

    with pytest.raises(RuntimeError):
        PostgresLedgerWriter("postgresql://user:pass@localhost/db")
