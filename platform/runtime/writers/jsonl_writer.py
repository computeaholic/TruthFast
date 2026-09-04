# operator/ledger/writers/jsonl_writer.py

import gzip
import json
import os
import time
from datetime import datetime, timezone

from runtime.ledger.schemas import LedgerEntry


class JSONLLedgerWriter:
    def __init__(self, base_path: str, retention_days: int = 30):
        self.base_path = base_path
        os.makedirs(os.path.dirname(base_path), exist_ok=True)
        self.retention_days = retention_days

    def _current_log_path(self) -> str:
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        return f"{self.base_path}.{day}.log"

    def _rotate_and_compress(self, path: str):
        if not os.path.exists(path):
            return

        gz_path = path + ".gz"
        with open(path, "rb") as f_in:
            with gzip.open(gz_path, "wb") as f_out:
                f_out.write(f_in.read())

        os.remove(path)

    def _cleanup_old(self):
        cutoff = time.time() - (self.retention_days * 86400)
        folder = os.path.dirname(self.base_path)
        for f in os.listdir(folder):
            full = os.path.join(folder, f)
            if os.path.getmtime(full) < cutoff:
                os.remove(full)

    def write(self, entry: LedgerEntry):
        path = self._current_log_path()
        line = json.dumps(entry.as_dict(), ensure_ascii=False)
        with open(path, "a", encoding="utf-8") as f:
            f.write(line + "\n")

        # Daily rollover at midnight UTC
        if datetime.now(timezone.utc).hour == 0 and datetime.now(timezone.utc).minute == 0:
            self._rotate_and_compress(path)

        self._cleanup_old()
