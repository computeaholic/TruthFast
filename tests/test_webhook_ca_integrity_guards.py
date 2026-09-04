from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text()


def test_webhook_ca_verifier_exists() -> None:
    assert (REPO_ROOT / "scripts/verify/verify_webhook_ca_integrity.sh").exists()


def test_webhook_ca_verifier_uses_file_based_extraction_only() -> None:
    text = _read("scripts/verify/verify_webhook_ca_integrity.sh")
    assert 'active_root_pem="$(' not in text
    assert 'active_root_b64="$(' not in text
    assert 'mutating_cabundle="$(' not in text
    assert 'webhook_root="$(' not in text
    assert "mktemp -d" in text
    assert 'base64 -d "$unique_bundle" >"$pem_file"' in text


def test_webhook_ca_verifier_has_required_classifications() -> None:
    text = _read("scripts/verify/verify_webhook_ca_integrity.sh")
    assert "WEBHOOK_CA_INVALID_FORMAT" in text
    assert "WEBHOOK_CA_EMPTY" in text
    assert "WEBHOOK_CA_MISMATCH" in text
    assert "WEBHOOK_CA_NOT_READY" in text
    assert "WEBHOOK_CA_DRYRUN_RETRIES" in text
    assert "WEBHOOK_CA_DRYRUN_INTERVAL_SECONDS" in text


def test_webhook_ca_verifier_validates_format_and_fingerprint() -> None:
    text = _read("scripts/verify/verify_webhook_ca_integrity.sh")
    assert 'openssl x509 -in "$file" -noout' in text
    assert 'openssl x509 -in "$in_file" -noout -fingerprint -sha256' in text
    assert 'cmp -s "$spire_fp_file" "$webhook_fp_file"' in text


def test_webhook_ca_verifier_checks_spire_istio_and_webhook_match() -> None:
    text = _read("scripts/verify/verify_webhook_ca_integrity.sh")
    assert "extract_spire_root_to_file" in text
    assert "extract_single_webhook_cabundle_to_file" in text
    assert "verify_webhook_ca_matches_or_is_signed_by_spire_root" in text
    expected_call = (
        'verify_webhook_ca_matches_or_is_signed_by_spire_root '
        '"$spire_root_pem" "$webhook_pem" "$spire_fp" "$webhook_fp"'
    )
    assert expected_call in text
    assert "wait_for_dryrun_probe" in text
    assert "run_dryrun_probe" in text


def test_legacy_reconcile_script_is_now_wrapper() -> None:
    text = _read("scripts/proof/reconcile_webhook_ca_bundle.sh")
    assert 'exec bash "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh" "$@"' in text
