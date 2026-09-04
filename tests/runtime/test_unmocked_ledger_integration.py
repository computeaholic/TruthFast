"""Integration test: Unmocked ledger write + signature verification.

This test exists to prevent regressions hidden by mocked ledger paths.
It uses the real `OperatorLedger` logic but wires a deterministic, local
SQLite-backed writer (test-only) so we can verify persistence and signature
verification without requiring external infrastructure.
"""

from __future__ import annotations

import base64
import json
import sqlite3
from datetime import datetime, timedelta, timezone

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from runtime.authority import signing
from runtime.authority.state import AuthorityState, clear_validated_identity, set_state, set_validated_identity
from runtime.ledger.operator_ledger import OperatorLedger


class SQLiteLedgerWriter:
    """Minimal SQLite-backed LedgerWriter for integration testing.

    Implements write(entry) and get_last_seal(). Stores a subset of
    fields required for verification: seal, prev_seal, identity_hash,
    authority_signature, payload (JSON), ts.
    """

    def __init__(self, db_path: str):
        self.conn = sqlite3.connect(db_path)
        cur = self.conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS operator_ledger_v2 (
                id TEXT PRIMARY KEY,
                ts REAL,
                trace_id TEXT,
                sender TEXT,
                recipient TEXT,
                op TEXT,
                payload TEXT,
                prev_seal TEXT,
                seal TEXT,
                identity_hash TEXT,
                authority_signature TEXT,
                spiffe_id TEXT,
                identity_attested INTEGER
            )
            """
        )
        self.conn.commit()

    def write(self, entry):
        # Compute authority signature if present in environment (mirrors Postgres writer behavior)
        authority_signature = None
        identity_attested = int(bool(entry.identity and entry.identity.attested))
        identity_hash = entry.identity_hash
        seal = entry.seal
        if identity_attested and identity_hash and seal:
            # sign using the real signing helper which reads env var THREADFORGE_AUTHORITY_PRIVATE_KEY
            priv = signing.load_authority_private_key()
            authority_signature = signing.sign_authority_material(priv, seal, identity_hash)

        import uuid

        cur = self.conn.cursor()
        cur.execute(
            (
                "INSERT INTO operator_ledger_v2 (id, ts, trace_id, sender, recipient, op, payload, "
                "prev_seal, seal, identity_hash, authority_signature, spiffe_id, identity_attested) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)"
            ),
            (
                str(uuid.uuid4()),
                entry.ts,
                entry.trace_id,
                entry.sender,
                entry.recipient,
                entry.op,
                json.dumps(entry.payload or {}),
                entry.prev_seal,
                seal,
                identity_hash,
                authority_signature,
                getattr(entry.identity, "spiffe_id", None),
                identity_attested,
            ),
        )
        self.conn.commit()

    def write_many(self, entries):
        for e in entries:
            self.write(e)

    def get_last_seal(self) -> str:
        cur = self.conn.cursor()
        cur.execute("SELECT seal FROM operator_ledger_v2 ORDER BY ts DESC LIMIT 1")
        row = cur.fetchone()
        return row[0] if row and row[0] else "GENESIS"

    def close(self):
        self.conn.close()


def test_unmocked_ledger_write_and_signature_verifies(tmp_path, monkeypatch):
    """Writes a governance intent through OperatorLedger to a SQLite writer
    and verifies the stored authority signature matches the seal+identity_hash.

    This test exists to prevent regressions hidden by mocked ledger paths.
    """

    # Generate ephemeral RSA keypair for signing and expose via env var used by load_authority_private_key
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("utf-8")

    monkeypatch.setenv("THREADFORGE_AUTHORITY_PRIVATE_KEY", pem)

    # Prepare authority validated identity and authoritative state
    identity_hash = "test-identity-hash-0001"
    future_iso = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    set_validated_identity("spiffe://identity.threadforge.local/test", identity_hash, future_iso)
    set_state(AuthorityState.AUTHORITATIVE)

    # Create operator ledger and wire in our SQLite writer
    db_file = tmp_path / "ledger.db"
    writer = SQLiteLedgerWriter(str(db_file))

    ledger = OperatorLedger()
    ledger._writer = writer  # inject test writer

    # Perform a governance intent record which uses authoritative path and must be persisted
    governance_action_id = "test-action-0001"

    ledger.record_governance_intent(
        spiffe_principal="spiffe://identity.threadforge.local/test",
        action="test_action",
        verdict="INTERCEPT",
        parameters={"k": "v"},
        governance_action_id=governance_action_id,
    )

    # Force flush to ensure writer.write() is called
    ledger.flush()

    # Verify a row exists in SQLite
    cur = writer.conn.cursor()
    # The governance_action_id is recorded as part of the event; select by op and sender
    sql = (
        "SELECT id, payload, op, seal, identity_hash, authority_signature, spiffe_id "
        "FROM operator_ledger_v2 WHERE op=? AND sender=?"
    )
    cur.execute(sql, ("governance_intent", "spiffe://identity.threadforge.local/test"))
    row = cur.fetchone()
    assert row is not None, "Expected a written ledger row for the governance intent"

    _id, payload_json, op, seal, persisted_identity_hash, authority_signature_b64, spiffe_id = row

    assert op == "governance_intent"
    assert spiffe_id == "spiffe://identity.threadforge.local/test"
    assert persisted_identity_hash == identity_hash
    assert seal is not None
    assert authority_signature_b64 is not None, "authority_signature should be present for attested identity"

    # Verify signature using public key
    pub = key.public_key()
    signature = base64.b64decode(authority_signature_b64)
    material = (seal + "|" + persisted_identity_hash).encode("utf-8")

    pub.verify(
        signature,
        material,
        padding.PKCS1v15(),
        hashes.SHA256(),
    )

    # Cleanup
    writer.close()
    clear_validated_identity()
    set_state(AuthorityState.UNCLAIMED)
