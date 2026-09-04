import uuid
from datetime import datetime, timezone
from pathlib import Path

from prometheus_client import REGISTRY

from runtime.civ.provenance.artifact_writer import ArtifactWriter


class FakeSigner:
    def sign_artifact(self, json_str):
        return {
            "key_id": "fake-key",
            "algorithm": "ed25519",
            "signature": "a" * 128,
            "signed_content_hash": "deadbeef",
        }


class SimpleDecision:
    def __init__(self):
        self.decision_id = uuid.uuid4()
        self.generated_at = datetime.now(timezone.utc)
        self.provenance_hash = "deadbeef"

    def to_json_str(self):
        return "{}"


def test_write_decision_instruments_metric(tmp_path: Path):
    writer = ArtifactWriter(artifact_root=tmp_path, signer=FakeSigner())
    dec = SimpleDecision()

    res = writer.write_decision(decision=dec, write_json=True, write_markdown=False)
    assert "json_path" in res and "signature_path" in res

    val = REGISTRY.get_sample_value("smp_replay_reconstruction_total", {"result": "decision_written"})
    assert val is not None and float(val) >= 1.0
