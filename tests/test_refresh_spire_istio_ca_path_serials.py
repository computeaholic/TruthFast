from __future__ import annotations

import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "verify" / "refresh_spire_istio_ca_path.sh"


def _run(command: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", command],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )


def _prepare_test_ca(tmp_path: Path) -> dict[str, Path]:
    ca_key = tmp_path / "ca.key"
    ca_crt = tmp_path / "ca.crt"
    leaf_key = tmp_path / "leaf.key"
    leaf_csr = tmp_path / "leaf.csr"
    extfile = tmp_path / "leaf.ext"

    extfile.write_text(
        "basicConstraints=critical,CA:FALSE\n"
        "keyUsage=digitalSignature,keyEncipherment\n",
        encoding="utf-8",
    )

    commands = [
        f"openssl ecparam -name prime256v1 -genkey -noout -out {ca_key}",
        (
            "openssl req -x509 -new -key "
            f"{ca_key} -sha256 -days 365 -subj '/C=US/O=ThreadForge/CN=test-root' -out {ca_crt}"
        ),
        f"openssl genrsa -out {leaf_key} 2048",
        f"openssl req -new -key {leaf_key} -subj '/C=US/O=ThreadForge/CN=test-leaf' -out {leaf_csr}",
    ]
    for command in commands:
        result = _run(command, tmp_path)
        assert result.returncode == 0, result.stderr

    return {
        "ca_key": ca_key,
        "ca_crt": ca_crt,
        "leaf_key": leaf_key,
        "leaf_csr": leaf_csr,
        "extfile": extfile,
    }


def _sign_with_helper(
    tmp_path: Path,
    csr_path: Path,
    ca_cert_path: Path,
    ca_key_path: Path,
    serial_path: Path,
    out_path: Path,
    extfile_path: Path,
) -> subprocess.CompletedProcess[str]:
    command = f"""
set -euo pipefail
source "{SCRIPT}"
openssl_sign_request \
  "{csr_path}" \
  "{ca_cert_path}" \
  "{ca_key_path}" \
  "{serial_path}" \
  "{out_path}" \
  365 \
  "{extfile_path}"
"""
    return _run(command, tmp_path)


def test_refresh_script_uses_explicit_serial_helper() -> None:
    text = SCRIPT.read_text(encoding="utf-8")

    assert "openssl_sign_request()" in text
    assert '-CAserial "$serial_path" -CAcreateserial' in text
    assert '[[ -e "$serial_path" && ! -s "$serial_path" ]]' in text
    assert 'rm -f "$serial_path"' in text
    assert 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' in text


def test_refresh_script_uses_generic_pkey_matching_for_spire_root_key() -> None:
    text = SCRIPT.read_text(encoding="utf-8")

    assert '["openssl", "pkey", "-pubin", "-pubout", "-outform", "DER"]' in text
    assert '["openssl", "pkey", "-inform", "DER", "-in", kpath, "-pubout", "-outform", "PEM"]' in text
    assert '["openssl", "ec", "-pubin", "-in", "/dev/stdin", "-pubout", "-outform", "DER"]' not in text


def test_sign_helper_succeeds_when_serial_file_is_missing(tmp_path: Path) -> None:
    files = _prepare_test_ca(tmp_path)
    serial_path = tmp_path / "missing.srl"
    out_path = tmp_path / "leaf.crt"

    result = _sign_with_helper(
        tmp_path,
        files["leaf_csr"],
        files["ca_crt"],
        files["ca_key"],
        serial_path,
        out_path,
        files["extfile"],
    )

    assert result.returncode == 0, result.stderr
    assert out_path.exists()
    assert serial_path.exists()
    assert serial_path.read_text(encoding="utf-8").strip()


def test_sign_helper_recovers_from_empty_serial_file(tmp_path: Path) -> None:
    files = _prepare_test_ca(tmp_path)
    serial_path = tmp_path / "empty.srl"
    serial_path.write_text("", encoding="utf-8")
    out_path = tmp_path / "leaf.crt"

    result = _sign_with_helper(
        tmp_path,
        files["leaf_csr"],
        files["ca_crt"],
        files["ca_key"],
        serial_path,
        out_path,
        files["extfile"],
    )

    assert result.returncode == 0, result.stderr
    assert out_path.exists()
    assert serial_path.read_text(encoding="utf-8").strip()


def test_sign_helper_preserves_existing_serial_file(tmp_path: Path) -> None:
    files = _prepare_test_ca(tmp_path)
    serial_path = tmp_path / "existing.srl"
    serial_path.write_text("02\n", encoding="utf-8")
    out_path = tmp_path / "leaf.crt"

    result = _sign_with_helper(
        tmp_path,
        files["leaf_csr"],
        files["ca_crt"],
        files["ca_key"],
        serial_path,
        out_path,
        files["extfile"],
    )

    assert result.returncode == 0, result.stderr
    serial_after = serial_path.read_text(encoding="utf-8").strip()
    assert out_path.exists()
    assert serial_after
    assert serial_after != "02"


def test_sign_helper_supports_repeated_runs(tmp_path: Path) -> None:
    files = _prepare_test_ca(tmp_path)
    serial_path = tmp_path / "repeat.srl"
    out_one = tmp_path / "leaf-one.crt"
    out_two = tmp_path / "leaf-two.crt"

    first = _sign_with_helper(
        tmp_path,
        files["leaf_csr"],
        files["ca_crt"],
        files["ca_key"],
        serial_path,
        out_one,
        files["extfile"],
    )
    assert first.returncode == 0, first.stderr
    serial_after_first = serial_path.read_text(encoding="utf-8").strip()

    second = _sign_with_helper(
        tmp_path,
        files["leaf_csr"],
        files["ca_crt"],
        files["ca_key"],
        serial_path,
        out_two,
        files["extfile"],
    )
    assert second.returncode == 0, second.stderr
    serial_after_second = serial_path.read_text(encoding="utf-8").strip()

    assert out_one.exists()
    assert out_two.exists()
    assert serial_after_first
    assert serial_after_second
    assert serial_after_second != serial_after_first


def test_sign_helper_fails_closed_when_ca_key_does_not_match_cert(tmp_path: Path) -> None:
    files = _prepare_test_ca(tmp_path)
    other_key = tmp_path / "other-ca.key"
    other_cert = tmp_path / "other-ca.crt"
    mismatch_out = tmp_path / "mismatch.crt"
    serial_path = tmp_path / "mismatch.srl"

    for command in (
        f"openssl ecparam -name prime256v1 -genkey -noout -out {other_key}",
        (
            "openssl req -x509 -new -key "
            f"{other_key} -sha256 -days 365 -subj '/C=US/O=ThreadForge/CN=other-root' -out {other_cert}"
        ),
    ):
        result = _run(command, tmp_path)
        assert result.returncode == 0, result.stderr

    result = _sign_with_helper(
        tmp_path,
        files["leaf_csr"],
        files["ca_crt"],
        other_key,
        serial_path,
        mismatch_out,
        files["extfile"],
    )

    assert result.returncode != 0
    assert not mismatch_out.exists() or mismatch_out.stat().st_size == 0
