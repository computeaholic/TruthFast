"""Unit test: Verifies that ingest path executes without invoking ClickHouse when ClickHouse is unavailable.

This is a documented unit boundary: DB/network boundaries are mocked; the invariant is that the ingest path calls
`insert_rows` with ch == None (ClickHouse unavailable) and processes rows from Postgres.
"""

import importlib
import os
from types import SimpleNamespace
from typing import Any

import pytest  # type: ignore[reportMissingImports]

try:
    main_mod = importlib.import_module("ingest.value_plane.main")
except Exception as e:
    raise AssertionError(
        "Failed to import 'ingest.value_plane.main' — ensure repo is installed "
        "or PYTHONPATH is set (see tests/conftest.py)"
    ) from e

pytestmark: Any = pytest.mark.integration


@pytest.mark.unit
def test_ingest_falls_back_when_clickhouse_unavailable_unit(monkeypatch: Any):
    """Verifies that ingest path executes without invoking ClickHouse when ClickHouse is unavailable.

    Invariant: when `main_mod.Client` is None, `main_mod.insert_rows` is called with `ch is None` and receives
    the rows produced by `fetch_rows`.
    """
    # Arrange: simulate missing ClickHouse client
    monkeypatch.setattr(main_mod, "Client", None)  # type: ignore[reportUnknownMemberType]

    # Provide a dummy config for operator source (non-value)
    cfg = SimpleNamespace(
        pg_dsn="postgresql://user:pw@localhost/db",
        ch_host="localhost",
        ch_port=int(os.getenv("CLICKHOUSE_PORT", "9000")),
        ch_db="default",
        source="operator",
        batch_size=1,
    )
    monkeypatch.setattr(main_mod, "load_config", lambda: cfg)

    # Supply deterministic rows from fetch_rows so insert_rows gets exercised
    rows = [
        {
            "event_id": "e1",
            "created_at": "2026-01-01 00:00:00",
            "spiffe_id": "spiffe://test",
            "identity_class": "test",
            "payload": "{}",
        }
    ]
    monkeypatch.setattr(main_mod, "fetch_rows", lambda pg, table, cur, limit: rows)

    # Mock DB connection at the boundary: simple cursor context manager
    class DummyConn:
        def cursor(self) -> Any:
            class Ctx:
                def __enter__(self) -> Any:
                    class Cur:
                        def execute(self, *a: Any, **k: Any) -> None:
                            return None

                        def fetchone(self) -> Any:
                            return None

                        def fetchall(self) -> list[Any]:
                            return []

                    return Cur()

                def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
                    return None

            return Ctx()

        def commit(self) -> None:
            return None

        def close(self) -> None:
            return None

    # psycopg is a deferred import inside main() — patch the module directly
    import psycopg  # noqa: PLC0415

    monkeypatch.setattr(psycopg, "connect", lambda dsn: DummyConn())

    # Spy on insert_rows to assert fallback behavior
    called: dict[str, Any] = {}

    def spy_insert_rows(ch: Any, table: str, rws: list[dict], source: str) -> tuple[Any, Any]:
        called["called"] = True
        called["ch"] = ch
        called["rows"] = rws
        called["table"] = table
        called["source"] = source
        return (None, None)

    monkeypatch.setattr(main_mod, "insert_rows", spy_insert_rows)  # type: ignore[reportUnknownMemberType]

    # Act
    main_mod.main()

    # Assert: insert_rows was invoked and ch was None (fallback)
    assert called.get("called") is True, "insert_rows was not invoked"
    assert called["ch"] is None, "Expected ch to be None when ClickHouse is unavailable"
    assert called["rows"] == rows
    assert called["source"] == "operator"
