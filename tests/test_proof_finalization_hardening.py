from pathlib import Path
import json
import os
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[1]


def _finalizer_python_block(prove_system: str) -> str:
    start_marker = "if ! python3 - <<'PY' > \"$STATUS_JSON.tmp\""
    start = prove_system.index(start_marker)
    start = prove_system.index("import json", start)
    end = prove_system.index("\nPY\nthen", start)
    return prove_system[start:end]


def test_prove_system_evidence_tracks_normalized_verify_artifact() -> None:
    prove_system = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()

    assert '"verify.norm.log"' in prove_system
    assert '"verify.norm.log.sig"' in prove_system
    assert '"verify.log.sig"' not in prove_system
    assert 'assert_hashed_artifact_path_mutable "$log_file"' in prove_system


def test_prove_system_has_post_freeze_hashed_artifact_guard() -> None:
    prove_system = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()

    assert "PROOF_HASHED_ARTIFACTS_FROZEN=0" in prove_system
    assert "assert_artifact_not_frozen()" in prove_system
    assert "POST_FREEZE_HASHED_ARTIFACT_MUTATION" in prove_system
    assert "PROOF_HASHED_ARTIFACTS_FROZEN=1" in prove_system


def test_prove_system_builds_evidence_artifacts_from_frozen_set() -> None:
    prove_system = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()

    assert "update_status_evidence_artifacts()" in prove_system
    assert 'update_status_evidence_artifacts "$STATUS_STAGING_JSON" "$EVIDENCE_ARTIFACTS_JSON"' in prove_system
    assert prove_system.index("freeze_artifacts") < prove_system.index(
        'update_status_evidence_artifacts "$STATUS_STAGING_JSON" "$EVIDENCE_ARTIFACTS_JSON"'
    )


def test_prove_system_materializes_status_staging_before_finalization() -> None:
    prove_system = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()

    assert "seed_status_staging_json" in prove_system
    assert "The finalizer consumes status_staging.json as the canonical pre-final" in prove_system
    assert "EPHEMERAL_CONTAINERS_BLOCKED_STATUS" in prove_system
    assert prove_system.index("seed_status_staging_json") < prove_system.index("# Write status.json — all keys always present")


def test_prove_system_strips_run_scoped_fields_from_final_status() -> None:
    prove_system = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()

    assert 'for _volatile_key in ("run_id", "timestamp", "log_dir", "kubectl_context", "completion_record"):' in prove_system
    assert 'doc.pop(_volatile_key, None)' in prove_system


def test_prove_system_serializes_reason_payloads_via_data_boundaries() -> None:
    prove_system = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()
    finalizer = _finalizer_python_block(prove_system)

    assert 'reasons_raw = """$REASONS_JSON"""' not in finalizer
    assert 'signature_files_raw = """$EVIDENCE_SIGNATURE_FILES_JSON"""' not in finalizer
    assert 'artifacts_raw = """$EVIDENCE_ARTIFACTS_JSON"""' not in finalizer
    assert '"""$' not in finalizer
    assert "os.environ" in finalizer
    assert 'parsed("REASONS_JSON"' in finalizer
    assert 'parsed("EVIDENCE_SIGNATURE_FILES_JSON"' in finalizer
    assert 'parsed("EVIDENCE_ARTIFACTS_JSON"' in finalizer
    assert "status_path.exists()" in finalizer
    assert "doc = {}" in finalizer
    assert 'raise RuntimeError("proof status staging missing before finalization")' in finalizer
    assert '"$STATUS_STAGING_JSON"' not in finalizer
    assert '"$LOG_DIR"' not in finalizer
    assert '"$EXIT_SEMANTICS_CONSISTENT_STATUS"' not in finalizer
    assert '"$PHASE_BOOTSTRAP_REASON"' not in finalizer
    assert '"$PHASE_IDENTITY_REASON"' not in finalizer
    assert '"$PROOF_MODE"' not in finalizer

    specimens = [
        'Defaulted container "spire-server" out of: spire-server, init-spire-server-dirs (init)',
        'quote: "value"',
        "single quote: 'value'",
        "backslash: \\",
        "multi-line text\nsecond line",
        'JSON-like text: {"foo":"bar"}',
        r"shell metacharacters: $() ; `cmd`",
        "Unicode text: café ☃",
    ]
    payload = [{"type": "SYSTEM_REGRESSION", "component": "identity", "message": specimen} for specimen in specimens]
    reasons_json = json.dumps(payload, separators=(",", ":"))

    script = r"""
import json
import os
import pathlib

doc = {"evidence": {}}
doc.setdefault("evidence", {})["signature_files"] = json.loads(os.environ.get("EVIDENCE_SIGNATURE_FILES_JSON", "[]"))
doc.setdefault("evidence", {})["artifacts"] = json.loads(os.environ.get("EVIDENCE_ARTIFACTS_JSON", "{}"))
doc["reasons"] = json.loads(os.environ["REASONS_JSON"])
print(json.dumps(doc, sort_keys=True))
"""
    env = dict(os.environ)
    env["REASONS_JSON"] = reasons_json
    env["EVIDENCE_SIGNATURE_FILES_JSON"] = json.dumps(["verify.norm.log.sig", "status.json.sig"])
    env["EVIDENCE_ARTIFACTS_JSON"] = json.dumps({"status.json": "sha256:deadbeef"})
    proc = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["reasons"][0]["message"] == specimens[0]
    assert doc["reasons"][3]["message"] == specimens[3]
    assert doc["reasons"][4]["message"] == specimens[4]
    assert doc["reasons"][6]["message"] == specimens[6]
    assert doc["reasons"][7]["message"] == specimens[7]
    assert doc["evidence"]["signature_files"] == ["verify.norm.log.sig", "status.json.sig"]
    assert doc["evidence"]["artifacts"] == {"status.json": "sha256:deadbeef"}


def test_proof_finalizer_retains_failure_path_when_status_staging_is_missing() -> None:
    prove_system = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()
    finalizer = _finalizer_python_block(prove_system)

    assert 'env("FINAL") == "PASS"' in finalizer
    assert 'env("FAIL_CLASS") in {"", "NONE"}' in finalizer
    assert 'env("PROOF_RESULT") == "PASS"' in finalizer
    assert "doc = {}" in finalizer
    assert "status_path.exists()" in finalizer


def test_outage_verifier_does_not_print_pass_before_success() -> None:
    verifier = (REPO_ROOT / "scripts" / "verify" / "verify_no_cert_issuance_during_outage.sh").read_text()

    assert 'print("[PASS] outage blocked new connections and certificate issuance")' not in verifier
    assert 'echo "[PASS] outage blocked new connections and certificate issuance"' in verifier
    assert 'echo "[PASS] NO SPIRE -> NO VALID IDENTITY -> NO TRAFFIC"' in verifier
