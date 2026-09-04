from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[1]


def _run_purity_scan(repo_root: Path) -> subprocess.CompletedProcess[str]:
    script = f'''#!/usr/bin/env bash
set -euo pipefail
if grep -R "kubectl apply" "{repo_root}/scripts/proof" "{repo_root}/scripts/verify" | grep -v "dry-run"; then
  echo "[FAIL] kubectl apply detected in proof/verify path"
  exit 2
fi
'''
    return subprocess.run(
        ["bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", script],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )


def test_proof_purity_guard_accepts_repaired_validator() -> None:
    proc = _run_purity_scan(REPO_ROOT)

    output = proc.stdout + proc.stderr
    assert proc.returncode == 0, output
    assert "[FAIL] kubectl apply detected in proof/verify path" not in output


def test_proof_purity_guard_rejects_real_mutation_string_in_verifier_tree() -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
        repo_root = Path(tmpdir)
        (repo_root / "scripts" / "proof").mkdir(parents=True)
        (repo_root / "scripts" / "verify").mkdir(parents=True)
        (repo_root / "scripts" / "proof" / "placeholder.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        (repo_root / "scripts" / "verify" / "bad_verifier.py").write_text(
            "print('kubectl apply -f -')\n",
            encoding="utf-8",
        )

        proc = _run_purity_scan(repo_root)

        output = proc.stdout + proc.stderr
        assert proc.returncode == 2, output
        assert "[FAIL] kubectl apply detected in proof/verify path" in output
        assert "bad_verifier.py" in output or "kubectl apply -f -" in output


def test_proof_kubectl_wrapper_only_allows_read_only_rollout_status() -> None:
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text(encoding="utf-8")

    assert 'case "$cmd:$subcmd" in' in text
    assert 'rollout:status)' in text
    assert 'rollout restart' not in text[text.index('# Whitelist: read-only and observation operations only.'):text.index('helm() {')]
