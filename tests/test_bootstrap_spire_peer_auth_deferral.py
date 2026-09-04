from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "scripts" / "infra" / "bootstrap.sh"


def test_bootstrap_defers_spire_system_peerauth_until_istio_ready() -> None:
    text = BOOTSTRAP.read_text()

    assert "deferring spire-system PeerAuthentication until Istio is fully ready" in text
    assert "kubectl apply -f platform/deploy/infra/istio/security/peer-authentication-spire-system.yaml >/dev/null" not in text.split(
        'echo "[bootstrap] deferring spire-system PeerAuthentication until Istio is fully ready"'
    )[0]
