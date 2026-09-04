from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_hostile_tamper_uses_an_isolated_proof_tree() -> None:
    text = _read("scripts/verify/hostile_validation.sh")

    assert 'isolated_dir="$(mktemp -d)"' in text
    assert 'cp -a "$REPO_ROOT/artifacts/proof/latest/." "$isolated_dir/"' in text
    assert 'echo "tamper" >> "$isolated_dir/status.json"' in text
    assert 'canonical_before="$(sha256sum "$canonical_status")"' in text
    assert 'canonical_after="$(sha256sum "$canonical_status")"' in text
    assert 'canonical proof artifact changed during isolated tamper test' in text
    assert 'echo "tamper" >> "$target"' not in text


def test_make_tamper_target_redirects_signature_check_to_the_copy() -> None:
    text = _read("Makefile")

    assert 'echo "[TEST] Mutating isolated signed artifact"' in text
    assert 'STATUS_FILE="$$tmp_dir/status.json"' in text
    assert 'STATUS_SIG="$$tmp_dir/status.json.sig"' in text
    assert 'printf \' \\n\' >> "$$tmp_dir/status.json"' in text
