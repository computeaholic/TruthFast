from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "install" / "prepare_istio_images.sh"


def test_prepare_istio_images_uses_temp_cert_dir_with_ca_crt() -> None:
    text = SCRIPT.read_text()

    assert "REGISTRY_CERT_DIR=\"$(mktemp -d)\"" in text
    assert 'cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"' in text
    assert '--cert-dir "$REGISTRY_CERT_DIR"' in text
    assert '--src-cert-dir "$REGISTRY_CERT_DIR"' in text
    assert '--dest-cert-dir "$REGISTRY_CERT_DIR"' in text
    assert 'REGISTRY_CERT_DIR="$(dirname "$REGISTRY_CA_CERT_PATH")"' not in text
