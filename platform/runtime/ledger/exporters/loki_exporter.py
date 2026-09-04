# operator/ledger/exporters/loki_exporter.py

import json

import requests

from runtime.ledger.schemas import LedgerEntry


class LokiExporter:
    def __init__(self, endpoint: str, label_app: str = "runtime"):
        self.endpoint = endpoint
        # store structured labels so they can be used in payloads
        self.stream_labels = {"app": label_app, "agent": "Ella"}
        # legacy string form (if needed elsewhere)
        self.labels = f'{{app="{label_app}",agent="Ella"}}'

    def write(self, entry: LedgerEntry):
        # Fail-closed: exporting ledger entries must be authoritative
        from runtime.authority.state import is_authoritative

        if not is_authoritative():
            raise PermissionError("LokiExporter refused to write in non-authoritative runtime")

        ts_ns = int(entry.ts * 1_000_000_000)

        payload = {
            "streams": [
                {
                    # use structured labels (app + agent)
                    "stream": self.stream_labels,
                    "values": [[str(ts_ns), json.dumps(entry.as_dict())]],
                },
            ],
        }

        requests.post(
            f"{self.endpoint}/loki/api/v1/push",
            data=json.dumps(payload),
            headers={"Content-Type": "application/json"},
            timeout=0.5,
        )
