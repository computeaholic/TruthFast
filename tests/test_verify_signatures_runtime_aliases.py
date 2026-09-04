from __future__ import annotations

from pathlib import Path

import pytest

pytestmark = pytest.mark.core

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIFY_SIGNATURES = REPO_ROOT / "scripts" / "verify" / "verify_signatures.sh"


def test_verify_signatures_consumes_runtime_drift_projection() -> None:
    text = VERIFY_SIGNATURES.read_text()

    assert 'RUNTIME_DRIFT_CLASSIFICATION_PATH="${RUNTIME_DRIFT_CLASSIFICATION_PATH:-$REPO_ROOT/artifacts/runtime/runtime_drift_classification.json}"' in text
    assert 'effective_spec_ref' in text
    assert 'is_internal' in text
    assert 'resolution_kind' in text
    assert 'resolved_ref' in text


def test_verify_signatures_accepts_approved_runtime_drift_images() -> None:
    text = VERIFY_SIGNATURES.read_text()

    assert 'signature_expected_images[$canonical_image_ref]' in text
    assert 'print(f"{resolved.strip()}\\t{projected}")' in text


def test_verify_signatures_authenticates_registry_verification() -> None:
    text = VERIFY_SIGNATURES.read_text()

    assert 'REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"' in text
    assert 'REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"' in text
    assert '"${COSIGN_REGISTRY_AUTH_ARGS[@]}"' in text


def test_sign_images_bounds_and_retries_registry_inspect() -> None:
    text = (REPO_ROOT / "scripts" / "supply_chain" / "sign_images.sh").read_text()

    assert 'SKOPEO_INSPECT_TIMEOUT_SECONDS="${SKOPEO_INSPECT_TIMEOUT_SECONDS:-25}"' in text
    assert 'SKOPEO_INSPECT_RETRIES="${SKOPEO_INSPECT_RETRIES:-3}"' in text
    assert 'inspect_image_digest()' in text
    assert 'timeout "${SKOPEO_INSPECT_TIMEOUT_SECONDS}s"' in text
