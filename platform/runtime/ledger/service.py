# runtime/ledger/service.py
"""⚠️ NON-AUTHORITATIVE LEDGER

This service exists ONLY for:
- local dev
- jsonl fallback
- early bootstrap

DO NOT use in production paths.
OperatorLedger is the sole authoritative writer.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os

from runtime.ledger.seal import LedgerSealChain

# Runtime notice: informational—LedgerService is non-authoritative and intended for local/dev use.
# Downgrade to INFO to avoid alarming operators during normal non-authoritative operation.
logging.getLogger(__name__).info("LedgerService is non-authoritative; use OperatorLedger for production.")


_seal_chain = LedgerSealChain()


class LedgerService:
    def __init__(self, dsn: str | None = None, jsonl_path: str | None = None):
        self.dsn = dsn
        self.jsonl_path = jsonl_path

        if self.jsonl_path and not os.path.exists(self.jsonl_path):
            # Ensure parent directory exists and file exists
            parent = os.path.dirname(self.jsonl_path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(self.jsonl_path, "w"):
                pass

    def _hash_entry(self, prev_hash: str, entry: dict) -> str:
        payload = json.dumps(entry, sort_keys=True)
        material = f"{prev_hash}:{payload}".encode()
        return hashlib.sha256(material).hexdigest()

    def _get_last_hash(self) -> str:
        if self.jsonl_path is None:
            raise RuntimeError("jsonl_path is not configured")

        last = "GENESIS"
        with open(self.jsonl_path) as f:
            for line in f:
                obj = json.loads(line)
                last = obj["hash"]
        return last

    # -------------------------------------------------------------
    # Unified write-to-ledger (pg + jsonl)
    # -------------------------------------------------------------
    def append(self, entry: dict):
        if not self.jsonl_path:
            return

        prev_hash = self._get_last_hash()
        entry["prev_hash"] = prev_hash
        entry["hash"] = self._hash_entry(prev_hash, entry)

        with open(self.jsonl_path, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def verify_chain(self) -> None:
        if self.jsonl_path is None:
            raise RuntimeError("jsonl_path is not configured")

        prev = "GENESIS"
        with open(self.jsonl_path) as f:
            for idx, line in enumerate(f):
                entry = json.loads(line)
                expected = self._hash_entry(prev, {k: v for k, v in entry.items() if k not in ("hash",)})
                if entry["hash"] != expected:
                    raise ValueError(f"Ledger tamper detected at line {idx}")
                prev = entry["hash"]

    def write(self, entry: dict):
        """Legacy convenience: in development, LEGACY_DEV_MODE enables write().

        This method is intentionally disabled in production to enforce append-only
        immutability. When LEGACY_DEV_MODE is set (non-production), write() will
        append the entry to the jsonl file for local/dev use.
        """
        if os.getenv("LEGACY_DEV_MODE"):
            # Backwards-compatible behavior for dev: write is equivalent to append
            self.append(entry)
            return

        raise RuntimeError(
            "Ledger write() is permanently disabled. "
            "Ledger is append-only per Phase 10 immutability invariant. "
            "Use append() for all entries."
        )


# Singleton instance
ledger: LedgerService | None = None
