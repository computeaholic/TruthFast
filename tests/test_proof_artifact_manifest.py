from pathlib import Path
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_LIB = REPO_ROOT / "scripts" / "lib" / "proof_artifact_manifest.sh"


def _bash(command: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", command],
        cwd=cwd or REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def test_canonical_artifacts_hash_normalized_verify_log() -> None:
    result = _bash(f'source "{MANIFEST_LIB}" && proof_latest_artifact_names "/tmp/proof"')

    assert result.returncode == 0, result.stderr
    artifact_names = result.stdout.strip().splitlines()
    assert "verify.norm.log" in artifact_names
    assert "verify.log" not in artifact_names


def test_hash_manifest_uses_normalized_verify_log(tmp_path: Path) -> None:
    proof_dir = tmp_path / "proof"
    proof_dir.mkdir()
    (proof_dir / "verify.log").write_text(
        "2026-04-17T17:05:15Z pod-echo-1234 deadbeefcafebabe\n"
        "DURATION=5275ms\n"
        "[✓] Using Envoy pod for /certs verification: istio-system/istio-ingressgateway-abc12345-bv58q\n",
        encoding="utf-8",
    )
    (proof_dir / "observe.log").write_text("observe\n", encoding="utf-8")
    (proof_dir / "observability.json").write_text("{}\n", encoding="utf-8")
    (proof_dir / "workload_projection_continuity.json").write_text("{}\n", encoding="utf-8")
    (proof_dir / "determinism.json").write_text("{}\n", encoding="utf-8")
    (proof_dir / "ca_integrity.json").write_text("{}\n", encoding="utf-8")

    result = _bash(f'source "{MANIFEST_LIB}" && write_proof_hash_manifest "{proof_dir}"')

    assert result.returncode == 0, result.stderr
    normalized = (proof_dir / "verify.norm.log").read_text(encoding="utf-8")
    assert normalized == (
        "<TIMESTAMP> <POD> <HEX>\n" "DURATION=<DURATION>\n" "[✓] Using Envoy pod for /certs verification: <POD>\n"
    )

    hash_manifest = (proof_dir / "hashes.txt").read_text(encoding="utf-8")
    assert "verify.norm.log" in hash_manifest
    assert "verify.log" not in hash_manifest
    assert "workload_projection_continuity.json" in hash_manifest


def test_hash_manifest_regeneration_is_blocked_after_freeze(tmp_path: Path) -> None:
    proof_dir = tmp_path / "proof"
    proof_dir.mkdir()
    (proof_dir / "verify.log").write_text("verify\n", encoding="utf-8")
    (proof_dir / "observe.log").write_text("observe\n", encoding="utf-8")
    (proof_dir / "observability.json").write_text("{}\n", encoding="utf-8")
    (proof_dir / "workload_projection_continuity.json").write_text("{}\n", encoding="utf-8")
    (proof_dir / "determinism.json").write_text("{}\n", encoding="utf-8")
    (proof_dir / "ca_integrity.json").write_text("{}\n", encoding="utf-8")

    result = _bash(f'ARTIFACT_FROZEN=1; source "{MANIFEST_LIB}"; write_proof_hash_manifest "{proof_dir}"')

    assert result.returncode != 0
    assert "POST_FREEZE_HASHED_ARTIFACT_MUTATION" in result.stderr
