#!/usr/bin/env python3
"""Enforce ThreadForge's repository-only GitHub CI constitution."""

from __future__ import annotations

import ast
import json
import os
import re
import shlex
from collections.abc import Iterable
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_WORKFLOWS_DIR = ROOT / ".github" / "workflows"
WORKFLOWS_DIR = Path(os.environ.get("THREADFORGE_WORKFLOW_DIR", DEFAULT_WORKFLOWS_DIR))
CONTRACT_PATH = Path(
    os.environ.get("THREADFORGE_CI_CONTRACT", ROOT / "platform/config/ci_execution_allowlist.json")
)

ALLOWED_CLASSIFICATIONS = {"CI_STATIC", "CI_UNIT", "CI_DOCS", "CI_GOVERNANCE"}
DANGEROUS_PYTHON_IMPORTS = {
    "docker",
    "httpx",
    "kubernetes",
    "requests",
    "socket",
    "urllib",
}
SHELL_RUNTIME_COMMAND = re.compile(
    r"^\s*(?:sudo|kubectl|helm|kind|docker|podman|nerdctl|cosign|curl|wget|nc|ssh)(?:\s|$)"
)
SHELL_SCRIPT_REENTRY = re.compile(r"^\s*(?:bash|sh)\s+scripts/")
SHELL_RUNTIME_MAKE = re.compile(
    r"^\s*make\s+(?:validate-all(?:-full-reset)?|golden-boot|rebuild|infra-bootstrap|bootstrap|"
    r"cluster-reset|proof(?:-active|-determinism)?|prove-active|prove-spire-outage|demo(?:-all|-civ|"
    r"-authority-contrast|-security-boundary)?|forgesec|registry-audit|audit|runtime-(?:deploy-api|"
    r"init|nuke)|test-cluster|test-full|lock-validate)(?:\s|$)"
)
SHELL_RUNTIME_VARIABLE = re.compile(r"\b(?:KUBECTL|HELM|KIND|DOCKER|COSIGN|KUBECONFIG)\b")
SHELL_REENTRY = re.compile(r"^\s*(?:source|\.)\s+")


def _load_contract() -> dict[str, Any]:
    data = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError(f"{CONTRACT_PATH}: contract must be a mapping")
    return data


def _workflow_paths() -> list[Path]:
    if not WORKFLOWS_DIR.exists():
        return []
    # GitHub accepts both extensions; neither may bypass the repository contract.
    return sorted([*WORKFLOWS_DIR.glob("*.yml"), *WORKFLOWS_DIR.glob("*.yaml")])


def _load_workflow(path: Path) -> dict[str, Any]:
    data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    if not isinstance(data, dict):
        raise TypeError(f"{path}: workflow must parse to a mapping")
    return data


def _collect_values(node: object, wanted_key: str) -> Iterable[str]:
    if isinstance(node, dict):
        for key, value in node.items():
            if key == wanted_key and isinstance(value, str):
                yield value
            else:
                yield from _collect_values(value, wanted_key)
    elif isinstance(node, list):
        for item in node:
            yield from _collect_values(item, wanted_key)


def _normalize_run_body(body: str) -> str:
    body = re.sub(r"\\\s*\n\s*", " ", body)
    lines = []
    for raw_line in body.splitlines():
        line = " ".join(raw_line.strip().split())
        if line and not line.startswith("#"):
            lines.append(line)
    return "\n".join(lines)


def _assert_expected_workflows(contract: dict[str, Any], failures: list[str]) -> None:
    expected = set(contract["WORKFLOWS"])
    actual = {path.name for path in _workflow_paths()}
    if actual != expected:
        failures.append(f"workflow surface mismatch: expected={sorted(expected)} actual={sorted(actual)}")


def _assert_triggers(path: Path, workflow: dict[str, Any], failures: list[str]) -> None:
    triggers = workflow.get("on")
    if not isinstance(triggers, dict):
        failures.append(f"{path}: workflow trigger must be a mapping")
        return
    if set(triggers) != {"push", "pull_request", "workflow_dispatch"}:
        failures.append(f"{path}: only main push, main pull_request, and workflow_dispatch are allowed")
        return
    for event in ("push", "pull_request"):
        value = triggers.get(event)
        if not isinstance(value, dict) or value.get("branches") != ["main"]:
            failures.append(f"{path}: {event} trigger must be restricted to main")


def _assert_workflow_contract(contract: dict[str, Any], failures: list[str]) -> None:
    for path in _workflow_paths():
        workflow = _load_workflow(path)
        expected = contract["WORKFLOWS"].get(path.name)
        if not isinstance(expected, dict):
            continue
        _assert_triggers(path, workflow, failures)

        jobs = workflow.get("jobs")
        if not isinstance(jobs, dict) or set(jobs) != {expected["JOB"]}:
            failures.append(f"{path}: expected exactly job {expected['JOB']!r}")
            continue
        job = jobs[expected["JOB"]]
        if not isinstance(job, dict):
            failures.append(f"{path}: job must be a mapping")
            continue
        if job.get("runs-on") != contract["RUNNER"]:
            failures.append(f"{path}: runner must be {contract['RUNNER']!r}")

        actual_actions = list(_collect_values(job.get("steps", []), "uses"))
        if actual_actions != expected["ACTIONS"]:
            failures.append(f"{path}: action allowlist mismatch: {actual_actions}")

        actual_runs = [_normalize_run_body(body) for body in _collect_values(job.get("steps", []), "run")]
        if actual_runs != expected["RUN_BODIES"]:
            failures.append(f"{path}: run-body allowlist mismatch")


def _pytest_files(workflow: dict[str, Any]) -> list[str]:
    for body in _collect_values(workflow, "run"):
        normalized = _normalize_run_body(body).replace("\n", " ")
        marker = "python -m pytest -q "
        if marker in normalized:
            return [part for part in shlex.split(normalized.split(marker, 1)[1]) if part.endswith(".py")]
    return []


def _python_capability_violations(path: Path, source: str, contract: dict[str, Any]) -> list[str]:
    violations: list[str] = []
    tree = ast.parse(source, filename=str(path))
    imported: set[str] = set()
    subprocess_calls = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(alias.name.split(".", 1)[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".", 1)[0])
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            if isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess":
                subprocess_calls += 1
            if isinstance(node.func.value, ast.Name) and node.func.value.id == "os" and node.func.attr in {
                "popen",
                "system",
            }:
                violations.append(f"{path}: os.{node.func.attr} is not CI-safe")
    for module in sorted(imported & DANGEROUS_PYTHON_IMPORTS):
        violations.append(f"{path}: CI-selected Python imports runtime/network capability {module!r}")

    relative = str(path.relative_to(ROOT))
    exception = contract.get("SUBPROCESS_EXCEPTIONS", {}).get(relative)
    if subprocess_calls and not exception:
        violations.append(f"{path}: subprocess capability is not allowlisted")
    if subprocess_calls and exception:
        if subprocess_calls != exception["CALL_COUNT"] or exception["REQUIRED_TARGET"] not in source:
            violations.append(f"{path}: subprocess exception does not match the approved target")
    return violations


def _shell_capability_violations(path: Path, source: str) -> list[str]:
    violations: list[str] = []
    for line_number, raw_line in enumerate(source.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if SHELL_RUNTIME_COMMAND.search(line):
            violations.append(f"{path}:{line_number}: runtime/network command is forbidden in CI helper")
        if SHELL_SCRIPT_REENTRY.search(line) or SHELL_RUNTIME_MAKE.search(line):
            violations.append(f"{path}:{line_number}: runtime entrypoint is forbidden in CI helper")
        if SHELL_RUNTIME_VARIABLE.search(line):
            violations.append(f"{path}:{line_number}: runtime command variable is forbidden in CI helper")
        if SHELL_REENTRY.search(line):
            violations.append(f"{path}:{line_number}: transitive shell sourcing is not allowlisted")
    return violations


def _assert_transitive_surface(contract: dict[str, Any], failures: list[str]) -> None:
    for relative, classification in contract["TRANSITIVE_PATHS"].items():
        path = ROOT / relative
        if classification not in ALLOWED_CLASSIFICATIONS:
            failures.append(f"{relative}: CI classification {classification!r} is not allowed")
            continue
        if not path.is_file():
            failures.append(f"{relative}: allowlisted transitive path is missing")
            continue
        source = path.read_text(encoding="utf-8")
        if path.suffix == ".py":
            failures.extend(_python_capability_violations(path, source, contract))
        elif path.suffix == ".sh":
            failures.extend(_shell_capability_violations(path, source))

    workflow = _load_workflow(WORKFLOWS_DIR / "repository-quality.yml")
    selected = _pytest_files(workflow)
    if selected != contract["PYTEST_FILES"]:
        failures.append(f"repository-quality pytest allowlist mismatch: {selected}")
    for selected_path in selected:
        if contract["TRANSITIVE_PATHS"].get(selected_path) not in {"CI_STATIC", "CI_UNIT"}:
            failures.append(f"{selected_path}: selected pytest file lacks CI_STATIC/CI_UNIT classification")

    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    recipe_match = re.search(r"^docs-verify:\s*\n((?:\t[^\n]*\n?)+)", makefile, re.MULTILINE)
    actual_recipe = [] if not recipe_match else recipe_match.group(1).splitlines()
    if actual_recipe != ["\t@bash scripts/verify/verify_mkdocs_strict.sh"]:
        failures.append("Makefile: docs-verify transitive owner changed from approved helper")


def main() -> int:
    failures: list[str] = []
    try:
        contract = _load_contract()
        _assert_expected_workflows(contract, failures)
        _assert_workflow_contract(contract, failures)
        _assert_transitive_surface(contract, failures)
    except (OSError, TypeError, ValueError, KeyError, json.JSONDecodeError, yaml.YAMLError) as exc:
        failures.append(f"CI constitution could not be evaluated: {exc}")

    if failures:
        print("CI_CONSTITUTION=FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 2

    print("CI_CONSTITUTION=PASS")
    print("CI_EXECUTION_AUTHORITY=REPOSITORY_ONLY")
    print("CI_RUNTIME_EXECUTION=PROHIBITED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
