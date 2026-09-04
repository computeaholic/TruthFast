from __future__ import annotations

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
CLASSIFIER = ROOT / "scripts/lib/classify_cosign_failure.py"

pytestmark = pytest.mark.core


@pytest.mark.parametrize(
    ("return_code", "diagnostic", "expected"),
    [
        (1, "no signatures found", "SIGNATURE_ABSENT"),
        (1, "invalid signature", "SIGNATURE_INVALID"),
        (1, "public key mismatch", "SIGNATURE_KEY_MISMATCH"),
        (1, "rekor inclusion proof failed", "TRANSPARENCY_LOG_FAILURE"),
        (1, "unauthorized: authentication required", "REGISTRY_AUTH_FAILURE"),
        (1, "x509: certificate signed by unknown authority", "REGISTRY_TLS_FAILURE"),
        (1, "dial tcp: connection refused", "REGISTRY_TRANSPORT_FAILURE"),
        (124, "", "COSIGN_TIMEOUT"),
        (1, "unexpected cosign failure", "COSIGN_INTERNAL_FAILURE"),
    ],
)
def test_cosign_failure_classes_are_explicit(
    tmp_path: Path, return_code: int, diagnostic: str, expected: str
) -> None:
    input_path = tmp_path / "cosign.log"
    input_path.write_text(diagnostic, encoding="utf-8")

    result = subprocess.run(
        [
            "python3",
            str(CLASSIFIER),
            "classify",
            "--return-code",
            str(return_code),
            "--input",
            str(input_path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    assert result.stdout.strip() == expected


def test_cosign_diagnostic_redacts_credentials_but_preserves_failure_context(tmp_path: Path) -> None:
    input_path = tmp_path / "cosign.log"
    output_path = tmp_path / "redacted.log"
    input_path.write_text(
        "unauthorized password=super-secret https://threadforge:also-secret@registry.example\n",
        encoding="utf-8",
    )

    subprocess.run(
        [
            "python3",
            str(CLASSIFIER),
            "redact",
            "--input",
            str(input_path),
            "--output",
            str(output_path),
        ],
        check=True,
    )

    diagnostic = output_path.read_text(encoding="utf-8")
    assert "unauthorized" in diagnostic
    assert "super-secret" not in diagnostic
    assert "also-secret" not in diagnostic
    assert "[REDACTED]" in diagnostic


def test_signature_verifier_preserves_fail_closed_classification_and_diagnostics() -> None:
    text = (ROOT / "scripts/verify/verify_signatures.sh").read_text(encoding="utf-8")

    assert "SIGNATURE_VERIFICATION_FAILED" in text
    assert "COSIGN_FAILURE_CLASSIFIER" in text
    assert "COSIGN_DIAGNOSTIC_ROOT" in text
    assert "UNSIGNED_MANIFEST_IMAGE" not in text
    assert "exit 2" in text
