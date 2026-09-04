# runtime/ledger/replay.py

import json

from runtime.ledger.schemas import LedgerEntry
from runtime.ledger.seal import LedgerSealChain


class LedgerReplayEngine:
    def __init__(self, path: str):
        self.path = path

    def replay(self):
        with open(self.path) as f:
            for line in f:
                data = json.loads(line)
                entry = LedgerEntry(**data)
                yield entry


def verify_chain(path: str) -> bool:
    sealer = LedgerSealChain()
    with open(path) as f:
        for line in f:
            entry = json.loads(line)
            expected = sealer.seal({k: v for k, v in entry.items() if k != "seal"})
            if entry.get("seal") != expected:
                return False
    return True


def verify_ledger_file(path: str) -> bool:
    sealer = LedgerSealChain()
    with open(path) as f:
        for line in f:
            entry = json.loads(line)
            seal = entry.pop("seal", None)
            expected = sealer.seal(entry)
            if seal != expected:
                return False
    return True
