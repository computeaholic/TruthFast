import re
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_prove_system_has_explicit_finalization_markers_and_exit_guard():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()
    for marker in (
        "[DEBUG] freezing artifacts",
        "[DEBUG] entering finalization",
        "[DEBUG] signing artifacts",
        "[DEBUG] verifying artifacts",
        "[DEBUG] computing final",
        "[DEBUG] exiting proof",
        "[prove_system] EXITING",
    ):
        assert marker in text
    assert "run_proof_once" not in text


def test_classified_failure_exit_bypasses_err_trap_without_changing_code():
    source = (REPO_ROOT / "scripts/prove_system.sh").read_text()
    match = re.search(
        r"^exit_with_failure_class\(\) \{.*?^\}",
        source,
        flags=re.MULTILINE | re.DOTALL,
    )
    assert match, "classified failure helper is missing"

    harness = "\n".join(
        (
            "set -Eeuo pipefail",
            "on_err_trap() { echo '[FATAL] unexpected shell error' >&2; exit 99; }",
            "trap 'on_err_trap \"$LINENO\"' ERR",
            f"REPO_ROOT={str(REPO_ROOT)!r}",
            match.group(0),
            "exit_with_failure_class POLICY_VIOLATION 'classified test failure'",
        )
    )
    result = subprocess.run(
        ["bash", "-c", harness],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 2
    assert "[FAIL] POLICY_VIOLATION: classified test failure" in result.stdout
    assert "unexpected shell error" not in result.stderr


def test_verify_proof_artifacts_uses_offline_bundle_verification():
    text = (REPO_ROOT / "scripts" / "verify" / "verify_proof_artifacts.sh").read_text()
    assert "--offline" in text
    assert "--rekor-url" not in text


def test_verify_proof_artifacts_checks_authoritative_root_status_signature():
    text = (REPO_ROOT / "scripts" / "verify" / "verify_proof_artifacts.sh").read_text()

    assert "authoritative root status.json" in text
    assert 'root_status="$REPO_ROOT/artifacts/proof/status.json"' in text
    assert 'root_status_sig="${root_status}.sig"' in text
    assert '--signature "$root_status_sig"' in text


def test_verify_proof_artifacts_gates_successor_validation_on_prepare_due():
    text = (REPO_ROOT / "scripts" / "verify" / "verify_proof_artifacts.sh").read_text()

    assert 'if root_lifecycle.get("prepare_due") is True:' in text
    assert 'missing successor_root_validation.json when prepare_due is true' in text
    assert 'successor_validation.get("continuous_successor_policy_ok") is not True' in text
    assert 'successor_validation.get("successor_count", 0) < 1' in text


def test_verify_proof_artifacts_retains_fail_closed_successor_checks_when_due():
    text = (REPO_ROOT / "scripts" / "verify" / "verify_proof_artifacts.sh").read_text()

    assert 'if root_lifecycle.get("prepare_due") is True:' in text
    assert 'missing successor_root_validation.json when prepare_due is true' in text
    assert 'successor_validation.get("successor_published") is not True' not in text
    assert 'successor_validation.get("successor_key_available") is not True' not in text
    assert 'successor_validation.get("successor_overlap_valid") is not True' not in text
    assert 'successor_validation.get("bundle_publication_valid") is not True' not in text
    assert 'successor_validation.get("key_availability_valid") is not True' not in text
    assert 'successor_validation.get("lifecycle_continuity_preserved") is not True' not in text


def test_prove_system_uses_explicit_freeze_barrier_and_mode_scoping():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()
    assert "ARTIFACT_FROZEN=0" in text
    assert "assert_not_frozen()" in text
    assert "freeze_artifacts()" in text
    assert 'PROOF_MODE="$VERIFY_EXECUTION_MODE"' in text
    assert 'if [ "$VERIFY_EXECUTION_MODE" = "proof" ]; then' in text
    assert "# PASSIVE-MODE MUTATION GUARD" in text
    assert "proof-active must execute" in text


def test_signing_uses_precomputed_hash_manifest_and_fixed_artifact_set():
    sign_text = (REPO_ROOT / "scripts" / "proof" / "sign_proof_artifacts.sh").read_text()
    verify_text = (REPO_ROOT / "scripts" / "verify" / "verify_proof_artifacts.sh").read_text()
    helper_text = (REPO_ROOT / "scripts" / "lib" / "proof_artifact_manifest.sh").read_text()
    assert "proof_latest_artifact_names" in helper_text
    assert "write_proof_hash_manifest" in helper_text
    assert "hash manifest must be generated before signing" in sign_text
    assert "find . -maxdepth 1 -type f" not in sign_text
    assert 'proof_latest_artifact_names "$PROOF_DIR"' in sign_text
    assert 'proof_latest_artifact_names "$PROOF_DIR"' in verify_text


def test_signature_verification_cache_is_proof_local_and_reused_downstream():
    sign_text = (REPO_ROOT / "scripts" / "verify" / "verify_signatures.sh").read_text()
    injected_text = (REPO_ROOT / "scripts" / "verify" / "verify_injected_images.sh").read_text()

    assert "signature_verification_cache.json" in sign_text
    assert "source_sha" in sign_text
    assert "verified_image_count" in sign_text
    assert "PROOF_SIGNATURE_CACHE_PATH" in injected_text
    assert "CURRENT_SOURCE_SHA" in injected_text
    assert "cache hit" in injected_text
    assert "verified_signature_cache" in injected_text
