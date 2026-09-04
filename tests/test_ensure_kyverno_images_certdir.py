from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "infra" / "ensure_kyverno_images.sh"


def test_kyverno_image_helper_uses_temp_cert_dir() -> None:
    text = SCRIPT.read_text()

    assert "mktemp -d" in text
    assert "cleanup_registry_cert_dir" in text
    assert 'cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"' in text
    assert 'dirname "$REGISTRY_CA_CERT_PATH"' not in text
