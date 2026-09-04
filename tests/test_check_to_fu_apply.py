import subprocess
from pathlib import Path


def test_check_to_fu_apply_detects_occurrence(tmp_path):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    (repo_root / "platform" / "deploy").mkdir(parents=True)
    # Create a dummy file that includes 'tofu apply'
    target = repo_root / "platform" / "deploy" / "infra_to_fu.tf"
    target.write_text("# example\\n# this line contains tofu apply\\n# tofu apply --yes")

    # Run the check script pointing GIT_DIR to our tmp repo (script searches ./)
    script_path = Path(__file__).resolve().parents[1] / "scripts" / "debug" / "check_to_fu_apply.sh"
    proc = subprocess.run(["bash", str(script_path)], cwd=repo_root, capture_output=True, text=True)
    assert proc.returncode != 0
    assert "FOUND 'tofu apply' occurrences" in proc.stderr
