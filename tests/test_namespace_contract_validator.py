from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = REPO_ROOT / "scripts" / "verify" / "namespace_contract.py"
BOOTSTRAP = REPO_ROOT / "scripts" / "infra" / "bootstrap.sh"
CONVERGED = REPO_ROOT / "scripts" / "verify" / "verify_bootstrap_converged.sh"


def _run_validator(bootstrap_text: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmpdir:
        bootstrap_path = Path(tmpdir) / "bootstrap.sh"
        bootstrap_path.write_text(bootstrap_text, encoding="utf-8")
        return subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                "--bootstrap-file",
                str(bootstrap_path),
                "--converged-file",
                str(CONVERGED),
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )


def test_namespace_contract_validator_passes_on_current_bootstrap() -> None:
    proc = subprocess.run(
        ["python3", str(VALIDATOR)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    output = proc.stdout + proc.stderr
    assert proc.returncode == 0, output
    assert "NAMESPACE_INVENTORY=" in output
    assert "NAMESPACE_CONTRACT_MATRIX=" in output
    assert "threadforge-test" in output
    assert "threadforge-system" in output
    assert "observability" in output
    assert "[PASS] namespace contract verified" in output
    assert "[FAIL] NAMESPACE_CONTRACT_VIOLATIONS:" not in output


def test_namespace_contract_validator_uses_structural_observability_producer_marker() -> None:
    bootstrap_text = BOOTSTRAP.read_text(encoding="utf-8")
    assert "# namespace-contract: observability namespace producer" in bootstrap_text
    assert "kubectl apply -k platform/deploy/infra/observability/base" in bootstrap_text
    marker_line = bootstrap_text.index("# namespace-contract: observability namespace producer")
    apply_line = bootstrap_text.index("kubectl apply -k platform/deploy/infra/observability/base")
    assert marker_line < apply_line


def test_namespace_contract_validator_uses_structural_threadforge_test_producer_marker() -> None:
    bootstrap_text = BOOTSTRAP.read_text(encoding="utf-8")
    function_start = bootstrap_text.index("ensure_threadforge_test_namespace() {")
    function_end = bootstrap_text.index("require_threadforge_test_namespace() {", function_start)
    function_body = bootstrap_text[function_start:function_end]
    assert "# namespace-contract: threadforge-test namespace producer" in function_body
    assert "kubectl apply -f platform/deploy/infra/threadforge-test/namespace.yaml >/dev/null" in function_body


def test_namespace_contract_validator_rejects_consumer_before_producer() -> None:
    bootstrap_text = BOOTSTRAP.read_text(encoding="utf-8")
    bootstrap_text = bootstrap_text.replace(
        "publish_registry_ca_configmaps\nensure_threadforge_test_namespace\n",
        "publish_registry_ca_configmaps\n",
        1,
    )
    bootstrap_text = bootstrap_text.replace(
        "ensure_threadforge_test_namespace\nwait_for_kyverno_admission_ready\n",
        "wait_for_kyverno_admission_ready\nensure_threadforge_test_namespace\n",
        1,
    )

    proc = _run_validator(bootstrap_text)

    output = proc.stdout + proc.stderr
    assert proc.returncode == 2, output
    assert "threadforge-test:CONSUMER_BEFORE_PRODUCER" in output
    assert "NAMESPACE_CONTRACT_MATRIX=" in output
    assert "threadforge-test" in output


def test_namespace_contract_validator_rejects_observability_consumer_before_producer() -> None:
    bootstrap_text = BOOTSTRAP.read_text(encoding="utf-8")
    bootstrap_text = bootstrap_text.replace(
        "# namespace-contract: observability namespace producer\nkubectl apply -k platform/deploy/infra/observability/base\n",
        "kubectl apply -k platform/deploy/infra/observability/base\n",
        1,
    )
    bootstrap_text = bootstrap_text.replace(
        "label_namespace_injection observability enabled\n",
        "label_namespace_injection observability enabled\n# namespace-contract: observability namespace producer\n",
        1,
    )

    proc = _run_validator(bootstrap_text)

    output = proc.stdout + proc.stderr
    assert proc.returncode == 2, output
    assert "observability:CONSUMER_BEFORE_PRODUCER" in output
    assert "observability" in output


def test_namespace_contract_validator_rejects_threadforge_test_missing_producer_marker() -> None:
    bootstrap_text = BOOTSTRAP.read_text(encoding="utf-8")
    bootstrap_text = bootstrap_text.replace(
        "# namespace-contract: threadforge-test namespace producer\n",
        "",
        1,
    )

    proc = _run_validator(bootstrap_text)

    output = proc.stdout + proc.stderr
    assert proc.returncode == 2, output
    assert "threadforge-test:UNVERIFIED_BOOTSTRAP_NAMESPACE_PRODUCER" in output
