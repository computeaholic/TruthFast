from __future__ import annotations

from pathlib import Path
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "scripts" / "verify" / "verify_helm_template_integrity.sh"
GRAFANA_FILES = [
    REPO_ROOT / "platform" / "deploy" / "gitops" / "infra" / "observability" / "grafana.yaml",
    REPO_ROOT / "platform" / "deploy" / "infra" / "observability" / "base" / "grafana.yaml",
]


def _run_checker(*paths: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(CHECKER), *(str(path) for path in paths)],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def test_valid_grafana_manifests_pass_helm_template_integrity() -> None:
    result = _run_checker(*GRAFANA_FILES)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "OK: No malformed Helm template syntax found." in result.stdout


def test_valid_nested_json_and_valid_helm_template_pass(tmp_path: Path) -> None:
    nested_json = tmp_path / "nested-json.yaml"
    nested_json.write_text(
        """
apiVersion: v1
kind: ConfigMap
data:
  dashboard: |
    "fieldConfig": { "defaults": { "unit": "reqps" } }
    "fieldConfig": { "defaults": { "unit": "ms" } }
""".strip()
        + "\n",
        encoding="utf-8",
    )
    valid_helm = tmp_path / "valid-helm.yaml"
    valid_helm.write_text(
        """
apiVersion: v1
kind: ConfigMap
data:
  template: "{{ .Release.Namespace }}"
  template2: "{{- .Values.foo -}}"
""".strip()
        + "\n",
        encoding="utf-8",
    )

    result = _run_checker(nested_json, valid_helm)

    assert result.returncode == 0, result.stdout + result.stderr


def test_malformed_helm_spacing_is_rejected(tmp_path: Path) -> None:
    cases = {
        "spacey-open.yaml": "{ { .Release.Namespace } }\n",
        "spacey-open-only.yaml": "{ { foo }}\n",
        "spacey-close.yaml": "{{ foo } }\n",
    }
    paths = []
    for name, content in cases.items():
        path = tmp_path / name
        path.write_text(content, encoding="utf-8")
        paths.append(path)

    result = _run_checker(*paths)

    assert result.returncode == 2, result.stdout + result.stderr
    assert "Malformed Helm template syntax detected" in result.stdout


def test_checker_resolves_repo_from_script_path(tmp_path: Path) -> None:
    result = subprocess.run(
        ["bash", str(CHECKER)],
        cwd=tmp_path,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "OK: No malformed Helm template syntax found." in result.stdout
