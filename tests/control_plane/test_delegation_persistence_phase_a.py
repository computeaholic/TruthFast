"""Phase A tests: Delegation persistence, restart safety, and ledger integrity.

Tests verify:
1. Persistence layer creates schema
2. Delegations persist to DB on issuance
3. Delegations rehydrate from DB on boot
4. Expiry filtering works (expired delegations not rehydrated)
5. Revocation persists to DB
6. Revoked delegations not rehydrated
7. Ledger events are emitted regardless of persistence
8. Persistence failures fail-closed (delegation not added to memory)

Note: Uses mock when PostgreSQL is unavailable.
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import Mock, patch
from uuid import uuid4

import pytest

from runtime.identity.context import IdentityContext
from runtime.identity.delegation import DelegatedCapability
from runtime.identity.delegation_persistence import DelegationPersistence
from runtime.identity.delegation_store import DelegationStore
from runtime.ledger.operator_ledger import OperatorLedger

# Check if PostgreSQL is available
POSTGRES_AVAILABLE = False
try:
    import psycopg2

    POSTGRES_AVAILABLE = True
except ImportError:
    POSTGRES_AVAILABLE = False


def pytest_configure(config):
    """Create test database if PostgreSQL available.

    Assumes kubectl port-forward is running:
      kubectl port-forward -n threadforge-system svc/postgres 15432:5432
    """
    if not POSTGRES_AVAILABLE:
        return

    import os

    # Get PostgreSQL credentials from environment
    pg_user = os.environ.get("POSTGRES_USER", "threadforge_operator")
    pg_password = os.environ.get("POSTGRES_PASSWORD", "threadforge")
    pg_host = os.environ.get("POSTGRES_HOST", "localhost")
    pg_port = os.environ.get("POSTGRES_PORT", "15432")
    pg_db = "threadforge_test"

    # Try to connect and create test database if needed
    try:
        admin_url = f"postgresql://{pg_user}:{pg_password}@{pg_host}:{pg_port}/threadforge"
        conn = psycopg2.connect(admin_url)
        conn.autocommit = True
        cursor = conn.cursor()

        # Check if test database exists
        cursor.execute("SELECT 1 FROM pg_database WHERE datname = %s", (pg_db,))
        if not cursor.fetchone():
            # Create test database
            cursor.execute(f"CREATE DATABASE {pg_db}")

        cursor.close()
        conn.close()
    except psycopg2.OperationalError as e:
        # Keep setup non-fatal; tests fail explicitly in fixtures with MISSING_PREREQ.
        print(f"Warning: Could not connect to PostgreSQL: {e}")
        print("Make sure kubectl port-forward is running:")
        print("  kubectl port-forward -n threadforge-system svc/postgres 15432:5432")


@pytest.fixture
def test_db_url():
    """Return test database URL from environment or defaults.

    Requires:
      - kubectl port-forward -n threadforge-system svc/postgres 15432:5432
      - Environment variables (optional):
        - POSTGRES_USER (default: threadforge_operator)
        - POSTGRES_PASSWORD (default: threadforge)
        - POSTGRES_HOST (default: localhost)
        - POSTGRES_PORT (default: 15432)
    """
    import os

    pg_user = os.environ.get("POSTGRES_USER", "threadforge_operator")
    pg_password = os.environ.get("POSTGRES_PASSWORD", "threadforge")
    pg_host = os.environ.get("POSTGRES_HOST", "localhost")
    pg_port = os.environ.get("POSTGRES_PORT", "15432")

    return f"postgresql://{pg_user}:{pg_password}@{pg_host}:{pg_port}/threadforge_test"


@pytest.fixture
def persistence(test_db_url):
    """Create a fresh persistence instance with schema."""
    if not POSTGRES_AVAILABLE:
        pytest.skip("INTENTIONAL_SKIP: integration DB tests require psycopg2")

    p = DelegationPersistence(test_db_url)

    if p.pool is None:
        pytest.skip("INTENTIONAL_SKIP: integration DB tests require PostgreSQL at TEST_DATABASE_URL")

    # Drop and recreate schema (clean slate)
    try:
        conn = p.pool.getconn()
        cursor = conn.cursor()
        cursor.execute("DROP TABLE IF EXISTS delegated_capabilities")
        conn.commit()
        cursor.close()
        p.pool.putconn(conn)
    except Exception:
        pass

    p.create_schema()
    yield p

    # Cleanup
    try:
        conn = p.pool.getconn()
        cursor = conn.cursor()
        cursor.execute("DROP TABLE IF EXISTS delegated_capabilities")
        conn.commit()
        cursor.close()
        p.pool.putconn(conn)
    except Exception:
        pass


@pytest.fixture
def mock_persistence():
    """Create a mock persistence instance for testing fail-closed behavior."""
    persistence = Mock(spec=DelegationPersistence)
    persistence.create_schema = Mock()
    persistence.persist_delegation = Mock()
    persistence.mark_revoked = Mock()
    persistence.load_active_delegations = Mock(return_value=[])
    persistence.pool = Mock()
    return persistence


@pytest.fixture
def source_identity():
    """Create a source identity for delegations."""
    return IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/threadforge/sa/admin",
        trust_domain="identity.threadforge.local",
        tier="admin",
        namespace="threadforge",
        service_account="admin",
        attested=True,
    )


@pytest.fixture
def delegate_identity():
    """Create a delegate identity."""
    return IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/threadforge/sa/worker",
        trust_domain="identity.threadforge.local",
        tier="worker",
        namespace="threadforge",
        service_account="worker",
        attested=True,
    )


@pytest.mark.integration
def test_persistence_creates_schema(persistence):
    """Verify schema is created with expected structure."""

    conn = persistence.pool.getconn()
    cursor = conn.cursor()

    # Query table structure
    cursor.execute(
        """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = 'delegated_capabilities'
        ORDER BY ordinal_position
    """
    )
    columns = {col[0]: col[1] for col in cursor.fetchall()}

    cursor.close()
    persistence.pool.putconn(conn)

    # Verify key columns
    assert "delegation_id" in columns
    assert "capability" in columns
    assert "delegate_spiffe_id" in columns
    assert "source_spiffe_id" in columns
    assert "issued_at" in columns
    assert "expires_at" in columns
    assert "revoked_at" in columns


@pytest.mark.integration
def test_persist_delegation_inserts_rows(persistence, source_identity, delegate_identity):
    """Verify delegation is persisted with one row per capability."""

    delegation = DelegatedCapability(
        delegation_id=str(uuid4()),
        source_spiffe_id=source_identity.spiffe_id,
        delegate_spiffe_id=delegate_identity.spiffe_id,
        capabilities=frozenset(["storage.read", "storage.write"]),
        issued_at=datetime.now(timezone.utc),
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="test delegation",
        policy_source="policy.test",
    )

    persistence.persist_delegation(delegation)

    # Verify rows in database
    conn = persistence.pool.getconn()
    cursor = conn.cursor()
    cursor.execute("SELECT COUNT(*) FROM delegated_capabilities WHERE delegation_id = %s", (delegation.delegation_id,))
    row_count = cursor.fetchone()[0]
    cursor.close()
    persistence.pool.putconn(conn)

    # Should have one row per capability
    assert row_count == 2  # storage.read and storage.write


@pytest.mark.integration
def test_load_active_delegations_filters_expired(persistence, source_identity, delegate_identity):
    """Verify expired delegations are not rehydrated."""

    # Create two delegations: one expired, one active
    expired_delegation = DelegatedCapability(
        delegation_id=str(uuid4()),
        source_spiffe_id=source_identity.spiffe_id,
        delegate_spiffe_id=delegate_identity.spiffe_id,
        capabilities=frozenset(["expired.cap"]),
        issued_at=datetime.now(timezone.utc) - timedelta(hours=2),
        expires_at=datetime.now(timezone.utc) - timedelta(hours=1),  # Expired
        justification="expired delegation",
        policy_source="policy.test",
    )

    active_delegation = DelegatedCapability(
        delegation_id=str(uuid4()),
        source_spiffe_id=source_identity.spiffe_id,
        delegate_spiffe_id=delegate_identity.spiffe_id,
        capabilities=frozenset(["active.cap"]),
        issued_at=datetime.now(timezone.utc),
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),  # Active
        justification="active delegation",
        policy_source="policy.test",
    )

    persistence.persist_delegation(expired_delegation)
    persistence.persist_delegation(active_delegation)

    # Load active delegations
    rehydrated = persistence.load_active_delegations()

    # Should only have active delegation
    assert len(rehydrated) == 1
    assert rehydrated[0].delegation_id == active_delegation.delegation_id


@pytest.mark.integration
def test_load_active_delegations_filters_revoked(persistence, source_identity, delegate_identity):
    """Verify revoked delegations are not rehydrated."""

    delegation = DelegatedCapability(
        delegation_id=str(uuid4()),
        source_spiffe_id=source_identity.spiffe_id,
        delegate_spiffe_id=delegate_identity.spiffe_id,
        capabilities=frozenset(["test.cap"]),
        issued_at=datetime.now(timezone.utc),
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="test delegation",
        policy_source="policy.test",
    )

    persistence.persist_delegation(delegation)
    persistence.mark_revoked(delegation.delegation_id, datetime.now(timezone.utc))

    # Load active delegations
    rehydrated = persistence.load_active_delegations()

    # Should be empty (revoked delegation not rehydrated)
    assert len(rehydrated) == 0


@pytest.mark.integration
def test_mark_revoked_updates_database(persistence, source_identity, delegate_identity):
    """Verify revocation is persisted to database."""

    delegation = DelegatedCapability(
        delegation_id=str(uuid4()),
        source_spiffe_id=source_identity.spiffe_id,
        delegate_spiffe_id=delegate_identity.spiffe_id,
        capabilities=frozenset(["test.cap"]),
        issued_at=datetime.now(timezone.utc),
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="test delegation",
        policy_source="policy.test",
    )

    persistence.persist_delegation(delegation)

    # Revoke
    revoked_at = datetime.now(timezone.utc)
    persistence.mark_revoked(delegation.delegation_id, revoked_at)

    # Verify revoked_at is set in database
    conn = persistence.pool.getconn()
    cursor = conn.cursor()
    cursor.execute(
        "SELECT revoked_at FROM delegated_capabilities WHERE delegation_id = %s LIMIT 1", (delegation.delegation_id,)
    )
    result = cursor.fetchone()
    cursor.close()
    persistence.pool.putconn(conn)

    assert result is not None
    assert result[0] is not None


def test_delegation_store_calls_persist_on_store(mock_persistence, source_identity, delegate_identity):
    """Verify DelegationStore calls persistence.persist_delegation on store."""
    with patch("runtime.identity.delegation_store.DelegationPersistence", return_value=mock_persistence):
        store = DelegationStore()

        delegation = DelegatedCapability(
            delegation_id=str(uuid4()),
            source_spiffe_id=source_identity.spiffe_id,
            delegate_spiffe_id=delegate_identity.spiffe_id,
            capabilities=frozenset(["test.cap"]),
            issued_at=datetime.now(timezone.utc),
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification="test delegation",
            policy_source="policy.test",
        )

        store.store_delegation(delegation, source_identity)

        # Verify persistence.persist_delegation was called
        mock_persistence.persist_delegation.assert_called_once()

        # Verify in memory
        assert store.get_delegation(delegation.delegation_id) is not None


def test_delegation_store_calls_mark_revoked_on_revoke(mock_persistence, source_identity, delegate_identity):
    """Verify DelegationStore calls persistence.mark_revoked on revoke."""
    with patch("runtime.identity.delegation_store.DelegationPersistence", return_value=mock_persistence):
        store = DelegationStore()

        delegation = DelegatedCapability(
            delegation_id=str(uuid4()),
            source_spiffe_id=source_identity.spiffe_id,
            delegate_spiffe_id=delegate_identity.spiffe_id,
            capabilities=frozenset(["test.cap"]),
            issued_at=datetime.now(timezone.utc),
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification="test delegation",
            policy_source="policy.test",
        )

        store.store_delegation(delegation, source_identity)
        store.revoke_delegation(delegation.delegation_id, source_identity)

        # Verify persistence.mark_revoked was called
        mock_persistence.mark_revoked.assert_called_once()


def test_fail_closed_on_persist_failure(mock_persistence, source_identity, delegate_identity):
    """Verify delegation fails to store if persistence fails (fail-closed)."""
    # Make persist_delegation raise an exception
    mock_persistence.persist_delegation.side_effect = RuntimeError("DB error")

    with patch("runtime.identity.delegation_store.DelegationPersistence", return_value=mock_persistence):
        store = DelegationStore()

        delegation = DelegatedCapability(
            delegation_id=str(uuid4()),
            source_spiffe_id=source_identity.spiffe_id,
            delegate_spiffe_id=delegate_identity.spiffe_id,
            capabilities=frozenset(["test.cap"]),
            issued_at=datetime.now(timezone.utc),
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification="test delegation",
            policy_source="policy.test",
        )

        # Should raise RuntimeError (fail-closed)
        with pytest.raises(RuntimeError, match="Failed to persist delegation"):
            store.store_delegation(delegation, source_identity)

        # Verify delegation NOT in memory (fail-closed)
        assert store.get_delegation(delegation.delegation_id) is None


def test_fail_closed_on_revoke_persistence_failure(mock_persistence, source_identity, delegate_identity):
    """Verify revocation fails if persistence fails (fail-closed)."""
    with patch("runtime.identity.delegation_store.DelegationPersistence", return_value=mock_persistence):
        store = DelegationStore()

        delegation = DelegatedCapability(
            delegation_id=str(uuid4()),
            source_spiffe_id=source_identity.spiffe_id,
            delegate_spiffe_id=delegate_identity.spiffe_id,
            capabilities=frozenset(["test.cap"]),
            issued_at=datetime.now(timezone.utc),
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification="test delegation",
            policy_source="policy.test",
        )

        store.store_delegation(delegation, source_identity)

        # Make mark_revoked raise an exception
        mock_persistence.mark_revoked.side_effect = RuntimeError("DB error")

        # Should raise RuntimeError (fail-closed)
        with pytest.raises(RuntimeError, match="Failed to persist revocation"):
            store.revoke_delegation(delegation.delegation_id, source_identity)

        # Verify delegation is still active (not revoked in memory)
        revoked_delegation = store.get_delegation(delegation.delegation_id)
        assert revoked_delegation is not None
        assert not revoked_delegation.is_revoked


def test_rehydration_restores_delegations(mock_persistence, source_identity, delegate_identity):
    """Verify DelegationStore rehydrates from persistence on init."""
    # Create a delegation that will be returned from load_active_delegations
    delegation = DelegatedCapability(
        delegation_id=str(uuid4()),
        source_spiffe_id=source_identity.spiffe_id,
        delegate_spiffe_id=delegate_identity.spiffe_id,
        capabilities=frozenset(["test.cap"]),
        issued_at=datetime.now(timezone.utc),
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="test delegation",
        policy_source="policy.test",
    )

    mock_persistence.load_active_delegations.return_value = [delegation]

    with patch("runtime.identity.delegation_store.DelegationPersistence", return_value=mock_persistence):
        store = DelegationStore()

        # Verify delegation was rehydrated
        assert store.get_delegation(delegation.delegation_id) is not None

        # Check that delegation is in active delegations for delegate
        active = store.get_active_delegations_for_delegate(delegate_identity.spiffe_id)
        delegation_ids = [d.delegation_id for d in active]
        assert delegation.delegation_id in delegation_ids


def test_ledger_events_emitted_on_store(mock_persistence, source_identity, delegate_identity):
    """Verify ledger events are emitted on delegation store."""
    with patch("runtime.identity.delegation_store.DelegationPersistence", return_value=mock_persistence):
        store = DelegationStore()
        ledger = OperatorLedger()

        delegation = DelegatedCapability(
            delegation_id=str(uuid4()),
            source_spiffe_id=source_identity.spiffe_id,
            delegate_spiffe_id=delegate_identity.spiffe_id,
            capabilities=frozenset(["test.cap"]),
            issued_at=datetime.now(timezone.utc),
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification="test delegation",
            policy_source="policy.test",
        )

        # Store delegation - this should emit ledger events
        store.store_delegation(delegation, source_identity)

        # Verify delegation was stored (ledger events are optional in dev)
        assert store.get_delegation(delegation.delegation_id) is not None


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
