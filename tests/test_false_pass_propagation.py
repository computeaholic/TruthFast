from __future__ import annotations

from pathlib import Path
import importlib.util

from scripts.proof.proof_hardening import compute_final_status


ROOT = Path(__file__).resolve().parents[1]


def _registry_module():
    path = ROOT / "scripts" / "verify" / "registry_completeness.py"
    spec = importlib.util.spec_from_file_location("registry_completeness", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _status_schema_module():
    path = ROOT / "scripts" / "verify" / "verify_determinism_schema.py"
    spec = importlib.util.spec_from_file_location("verify_determinism_schema", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _all_pass_guarantees() -> dict[str, dict[str, str]]:
    return {
        "a": {"status": "PASS"},
        "b": {"status": "PASS"},
        "c": {"status": "PASS"},
    }


def test_required_verifier_failure_is_monotonic() -> None:
    results = [
        {"name": "A", "exit_code": 0, "result": "PASS"},
        {"name": "B", "exit_code": 11, "result": "FAIL"},
        {"name": "C", "exit_code": 0, "result": "PASS"},
    ]

    assert results[1]["result"] == "FAIL"
    assert compute_final_status(True, True, True, [], _all_pass_guarantees(), True) == "FAIL"


def test_registry_failure_cannot_report_supply_chain_pass() -> None:
    guarantees = _all_pass_guarantees()
    guarantees["b"]["status"] = "FAIL"

    assert compute_final_status(True, True, True, [], guarantees) == "FAIL"


def test_proof_latches_ignored_preflight_failure() -> None:
    text = (ROOT / "scripts/prove_system.sh").read_text(encoding="utf-8")

    assert "PREFLIGHT_FAILURE_DETECTED=1" in text
    assert 'required preflight verifier failed' in text
    assert 'IMAGE_SIGNING_STATUS="FAIL"' in text
    assert 'DIGEST_IDENTITY_ENFORCED_STATUS="FAIL"' in text
    assert 'REGISTRY_COMPLETENESS_STATUS="FAIL"' in text
    assert 'registry_completeness=FAIL' in text
    assert '"${PREFLIGHT_FAILURE_DETECTED:-0}" == "1"' in text


def test_preflight_capture_happens_before_conditionals() -> None:
    text = (ROOT / "scripts/prove_system.sh").read_text(encoding="utf-8")
    start = text.index("run_preflight_script() {")
    end = text.index("\n}\n", start) + 3
    function = text[start:end]

    assert 'env -u \'BASH_FUNC_kubectl%%\' -u \'BASH_FUNC_helm%%\' bash "$@"' in function
    assert 'if env -u \'BASH_FUNC_kubectl%%\' -u \'BASH_FUNC_helm%%\' bash "$@"' in function
    assert 'rc=$?' in function
    assert 'else\n    rc=$?\n  fi' in function
    assert function.index('rc=$?') < function.index('if [ "$rc" -eq 0 ]')
    assert 'awk -F= \'$1 == "RESULT"' in function
    assert 'FIRST_REQUIRED_PREFLIGHT_FAILURE_NAME="$script_name"' in function
    assert 'FIRST_REQUIRED_PREFLIGHT_FAILURE_EXIT="$rc"' in function
    assert 'return 0' in function


def test_preflight_failure_does_not_rewrite_unrelated_guarantees() -> None:
    text = (ROOT / "scripts/prove_system.sh").read_text(encoding="utf-8")
    gate = text[text.index('if [ "$PREFLIGHT_FAILURE_DETECTED" -eq 1 ]; then'):]
    gate = gate[:gate.index("\nfi", gate.index("emit_phase_event")) + 3]

    assert 'PHASE_VERIFY="FAIL"' in gate
    assert 'IMAGE_SIGNING_STATUS="FAIL"' not in gate
    assert 'DIGEST_IDENTITY_ENFORCED_STATUS="FAIL"' not in gate
    assert 'REGISTRY_COMPLETENESS_STATUS="FAIL"' not in gate


def test_registry_digest_set_postcondition_requires_exact_equality() -> None:
    module = _registry_module()
    expected = {"sha256:" + "a" * 64, "sha256:" + "b" * 64}

    complete = module.digest_set_postcondition(
        expected,
        [{"digest": digest, "status": "PASS"} for digest in expected],
    )
    assert complete["exact_equality"] is True
    assert complete["missing"] == []
    assert complete["excess"] == []

    incomplete = module.digest_set_postcondition(
        expected,
        [{"digest": "sha256:" + "a" * 64, "status": "PASS"}],
    )
    assert incomplete["exact_equality"] is False
    assert incomplete["missing"] == ["sha256:" + "b" * 64]


def test_registry_completeness_is_a_canonical_status_field() -> None:
    module = _status_schema_module()
    status = {key: True for key in module.REQUIRED_KEYS}
    status["registry_completeness"] = "PASS"

    missing, unknown = module.validate_status(status)

    assert missing == []
    assert unknown == []


def test_unknown_status_fields_remain_fail_closed() -> None:
    module = _status_schema_module()
    status = {key: True for key in module.REQUIRED_KEYS}
    status["registry_completeness"] = "FAIL"
    status["unsupported_status_field"] = "PASS"

    missing, unknown = module.validate_status(status)

    assert missing == []
    assert unknown == ["unsupported_status_field"]
