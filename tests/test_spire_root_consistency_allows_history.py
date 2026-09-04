from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "verify" / "verify_spire_root_consistency.sh"


def test_spire_root_consistency_does_not_require_single_bundle_root() -> None:
    text = SCRIPT.read_text()

    assert "expected exactly one SPIRE root" not in text
    assert "ROOTCA_COUNT_MISMATCH" not in text
    assert "no SPIRE roots found in active bundle" in text
    assert "bundle_serials" in text
    assert "bundle show" in text
    assert "SPIRE_SERVER_POD" in text
    assert "/run/spire/private/spire-server.sock" in text
    assert "bundle show" in text
    assert text.index("SPIRE_SERVER_POD") < text.index("bundle show")
