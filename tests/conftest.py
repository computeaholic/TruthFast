import importlib.util
import os
import sys
from pathlib import Path

# Must be set before any import of api.core.identity_config (which is imported transitively
# via api.deps). Setting here at module level ensures it is present for the entire test run.
os.environ.setdefault("SPIFFE_TRUST_DOMAIN", "identity.threadforge.local")
os.environ.setdefault("ENABLE_METADATA_FALLBACK", "true")

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from tests.threadforge_test_mode import (
    CLUSTER_TEST_MODES,
    get_skip_count,
    get_test_mode,
    increment_skip_count,
    reset_skip_count,
    validate_test_mode,
)

# Documented PYTHONPATH injection: ensure project root is on sys.path for tests.
# This avoids per-test sys.path hacks and keeps tests deterministic.
# Rule: do not mutate sys.path elsewhere; this single injection is the only allowed import topology helper.
REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

# Provide a safe test-time alias for optional `smp` imports without adding
# platform/runtime to sys.path (which would shadow top-level api package).
if importlib.util.find_spec("smp") is None:
    try:
        import runtime.smp as _runtime_smp  # noqa: PLC0415

        sys.modules.setdefault("smp", _runtime_smp)
    except ModuleNotFoundError:
        pass

# Set TEST_DATABASE_URL for DB integration tests when running with test-env-up.
os.environ.setdefault(
    "TEST_DATABASE_URL",
    "postgresql://threadforge_operator:threadforge@localhost:15432/threadforge_test",
)

_clickhouse_available = importlib.util.find_spec("clickhouse_driver") is not None


def pytest_configure(config):
    validate_test_mode()
    reset_skip_count()
    config._threadforge_test_mode = get_test_mode()
    config.addinivalue_line("markers", "unit: mark test as unit (pure, isolated)")
    config.addinivalue_line("markers", "integration: mark test as integration that exercises real systems")
    config.addinivalue_line("markers", "db: mark tests that require a DB (Postgres, ClickHouse, etc.)")
    config.addinivalue_line("markers", "control_plane: mark control plane / external behavior tests")
    config.addinivalue_line("markers", "smoke: mark smoke/build/integrity tests")
    config.addinivalue_line("markers", "clickhouse: mark test as requiring clickhouse-driver package")


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    items.sort(
        key=lambda item: (
            item.nodeid.startswith("tests/test_test_mode_enforcement.py::"),
            item.nodeid,
        )
    )


def pytest_collectreport(report: pytest.CollectReport) -> None:
    if report.outcome == "skipped":
        increment_skip_count()


def pytest_runtest_logreport(report: pytest.TestReport) -> None:
    if report.outcome == "skipped" and report.when in {"setup", "call"}:
        increment_skip_count()


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    if get_test_mode() in CLUSTER_TEST_MODES and get_skip_count() > 0 and exitstatus == 0:
        session.exitstatus = pytest.ExitCode.TESTS_FAILED


def pytest_terminal_summary(terminalreporter) -> None:
    terminalreporter.write_line(f"TEST MODE: {get_test_mode()}")
    terminalreporter.write_line(f"SKIPS: {get_skip_count()}")


# NOTE: Per project policy, tests must ASSERT availability of optional dependencies rather than silently SKIP.
# The previous behavior that auto-skipped clickhouse-marked tests is intentionally removed.
# Tests should perform assertive import checks (AssertionError) when a dependency is missing.


@pytest.fixture(scope="session", autouse=True)
def set_test_signing_key_env():
    """Autouse fixture: generates an Ed25519 key for tests and sets CIV_SIGNING_KEY env var.

    Tests that validate missing/invalid CIV_SIGNING_KEY can still monkeypatch or delete the env var explicitly.
    """
    key = Ed25519PrivateKey.generate()
    from cryptography.hazmat.primitives import serialization

    # Use raw private key bytes and set as hex in CIV_SIGNING_KEY for tests
    key_bytes = key.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    os.environ.setdefault("CIV_SIGNING_KEY", key_bytes.hex())


@pytest.fixture(autouse=True)
def reset_autonomy_constraint_manager():
    from runtime.governance.autonomy_constraint import get_autonomy_constraint_manager

    get_autonomy_constraint_manager().reset()
